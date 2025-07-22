#!/bin/bash
#=================================================================
# Bootstrap script for setting up the environment
#=================================================================

# Check if the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Use sudo."
    exit 1
fi

# =======================
# Function to install K3s
# =======================
k3s_install() {
    options=("Install K3s with default settings" "Install K3s with custom settings" "Back to main menu")
    PS3="Please select an option: "
    select opt in "${options[@]}"; do
        case $opt in
            "Install K3s with default settings")
                echo "Installing K3s with default settings..."
                # Check if K3s is already installed
                if command -v k3s &> /dev/null; then
                    echo "K3s is already installed."
                    exit 0
                fi
                # Install K3s using the official installation script
                curl -sfL https://get.k3s.io | sh -
                # Check if K3s was installed successfully
                if command -v k3s &> /dev/null; then
                    echo "K3s installed successfully."
                    echo "You can now use 'k3s kubectl' to interact with your K3s cluster."
                else
                    echo "Failed to install K3s."
                    exit 1
                fi
                break
                ;;
            "Install K3s with custom settings")
                echo "Installing K3s with custom settings..."
                echo "The custom settings includes the following options:"
                echo "1. Disables Traefik"
                echo "2. Disables Flannel"
                echo "3. Disables Network Policy"
                echo "4. Disables Service Load Balancer and Kube Proxy"
                echo "5. Installs Cilium CNI"
                # Check if K3s is already installed
                if command -v k3s &> /dev/null; then
                    echo "K3s is already installed."
                    exit 0
                fi
                # Generate random token for K3s
                K3S_TOKEN=$(openssl rand -hex 32)
                # Install K3s with custom settings
                curl -sfL https://get.k3s.io | K3S_TOKEN=$K3S_TOKEN sh -s - --flannel-backend=none --disable=traefik --disable-network-policy --disable=servicelb --disable-kube-proxy
                # Check if K3s was installed successfully
                if command -v k3s &> /dev/null; then
                    echo "K3s installed successfully with custom settings."
                    echo "You can now use 'k3s kubectl' to interact with your K3s cluster."

                    # Copy K3s token to a file
                    echo $K3S_TOKEN > /home/$SUDO_USER/k3s_token
                    echo "K3s token saved to /home/$SUDO_USER/k3s_token"

                    # Copy kubeconfig to the root and user's home directory
                    if [ -f /etc/rancher/k3s/k3s.yaml ]; then
                        # Copy kubeconfig to root's home directory
                        mkdir -p $HOME/.kube
                        sudo cp /etc/rancher/k3s/k3s.yaml $HOME/.kube/config
                        sudo chown $(id -u):$(id -g) $HOME/.kube/config
                        echo "Kubeconfig copied to $HOME/.kube/config"

                        # Copy kubeconfig to user's home directory
                        if [ -d /home/$SUDO_USER ]; then
                            sudo mkdir -p /home/$SUDO_USER/.kube
                            sudo cp /etc/rancher/k3s/k3s.yaml /home/$SUDO_USER/.kube/config
                            sudo chown $SUDO_USER:$SUDO_USER /home/$SUDO_USER/.kube/config
                            echo "Kubeconfig copied to /home/$SUDO_USER/.kube/config"
                        else
                            echo "User home directory /home/$SUDO_USER does not exist. Skipping kubeconfig copy."
                        fi
                    else
                        echo "Kubeconfig file not found. Please check the K3s installation."
                        exit 1
                    fi

                    # Install Cilium CNI
                    # Check if Cilium CLI is already installed
                    if command -v cilium &> /dev/null; then
                        echo "Cilium CNI is already installed."
                    else
                        echo "Installing Cilium CLI..."
                        CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
                        CLI_ARCH=amd64
                        if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
                        curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
                        sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
                        sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
                        rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
                        # Check if Cilium CLI was installed successfully
                        if command -v cilium &> /dev/null; then
                            echo "Cilium CNI installed successfully."
                        else
                            echo "Failed to install Cilium CLI."
                            exit 1
                        fi
                    fi

                    # Install Cilium CNI in the K3s cluster
                    LATEST_STABLE_CILIUM_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium/main/stable.txt)
                    LATEST_STABLE_CILIUM_VERSION=${LATEST_STABLE_CILIUM_VERSION#v}
                    cilium install --version ${LATEST_STABLE_CILIUM_VERSION}
                    if [[ $? -eq 0 ]]; then
                        echo "Cilium CNI installed successfully in the K3s cluster."
                    else
                        echo "Failed to install Cilium CNI in the K3s cluster."
                        exit 1
                    fi

                    # Display the join command for other nodes
                    LOCAL_IP=$(hostname -I | awk '{print $1}')
                    # Command to join master nodes
                    echo "This command can be used on master nodes to join the cluster:"
                    echo "curl -sfL https://get.k3s.io | K3S_URL=https://$LOCAL_IP:6443 sh -s - server --token $K3S_TOKEN"
                    # Command to join worker nodes
                    echo "This command can be used on worker nodes to join the cluster:"
                    echo "curl -sfL https://get.k3s.io | K3S_URL=https://$LOCAL_IP:6443 sh -s - agent --token $K3S_TOKEN"
                else
                    echo "Failed to install K3s with custom settings."
                    exit 1
                fi
                break
                ;;
            "Back to main menu")
                echo "Returning to main menu..."
                return
                ;;
            *)
                echo "Invalid option. Please try again."
                ;;
        esac
    done
}

# ============================
# Function to provision ArgoCD
# ============================
argocd_k8s_provision() {
    echo "Provisioning ArgoCD in K3s cluster..."
    # Check if K3s is installed
    if ! command -v k3s &> /dev/null; then
        echo "K3s is not installed. Please install K3s first."
        exit 1
    fi

    # Check if Helm is installed
    if ! command -v helm &> /dev/null; then
        echo "Helm is not installed. Installing Helm..."
        # Install Helm using the official installation script
        curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
        chmod 700 get_helm.sh
        ./get_helm.sh
        rm get_helm.sh
        # Check if Helm was installed successfully
        if command -v helm &> /dev/null; then
            echo "Helm installed successfully."
        else
            echo "Failed to install Helm."
            exit 1
        fi
    fi

    # Install ArgoCD using Helm
    echo "Installing ArgoCD..."
    # Create namespace for ArgoCD
    kubectl create namespace argocd
    # Install ArgoCD using repository configuration
    # Check if kustomize is installed
    if ! command -v kustomize &> /dev/null; then
        echo "Kustomize is not installed. Installing Kustomize..."
        KUSTOMIZE_LATEST_VERSION=$(curl -s https://api.github.com/repos/kubernetes-sigs/kustomize/releases/latest | grep -oP "tag_name\": \"\K[^\"]+")
        curl -sSL -o kustomize_linux_amd64.tar.gz https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_LATEST_VERSION}/kustomize_${KUSTOMIZE_LATEST_VERSION}_linux_amd64.tar.gz
        tar -xzf kustomize_linux_amd64.tar.gz
        sudo mv kustomize /usr/local/bin/
        rm kustomize_linux_amd64.tar.gz
    fi

    # Add the gitops-core repository to ArgoCD
    echo "Adding gitops-core repository to ArgoCD..."
    kustomize build ../applications/argocd/base | kubectl apply -f -
    if [ $? -eq 0 ]; then
        echo "gitops-core repository added to ArgoCD successfully."
    fi

    # Check if ArgoCD was installed successfully
    if kubectl get pods -n argocd &> /dev/null; then
        echo "ArgoCD provisioned successfully."
    else
        echo "Failed to provision ArgoCD."
        exit 1
    fi
}

# ==============================
# Function to install ArgoCD CLI
# ==============================
argocd_cli_install() {
    # Check if ArgoCD CLI is already installed
    if command -v argocd &> /dev/null; then
        echo "ArgoCD CLI is already installed."
        return
    fi

    echo "Installing ArgoCD CLI..."
    # Check if the system is Linux
    if [[ "$(uname -s)" == "Linux" ]]; then
        # Download the latest stable version of ArgoCD CLI
        VERSION=$(curl -L -s https://raw.githubusercontent.com/argoproj/argo-cd/stable/VERSION)
        curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/download/v$VERSION/argocd-linux-amd64
        sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
        rm argocd-linux-amd64
        # Check if the installation was successful
        if command -v argocd &> /dev/null; then
            echo "ArgoCD CLI installed successfully."
        else
            echo "Failed to install ArgoCD CLI."
            exit 1
        fi
    # Check if the system is macOS
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        # Check if Homebrew is installed
        if command -v brew &> /dev/null; then
            # Install ArgoCD CLI using Homebrew
            brew install argocd
            # Check if last command was successful
            if [ $? -eq 0 ]; then
                echo "ArgoCD CLI installed successfully."
            else
                echo "Failed to install ArgoCD CLI."
                exit 1
            fi
        else
            echo "Homebrew is not installed. Please install Homebrew first."
            exit 1
        fi
    else
        echo "Unsupported operating system. This script only supports Linux and macOS."
        exit 1
    fi
}

# =======================
# Function to install K9s
# =======================
k9s_install() {
    # Check if K9s is already installed
    if command -v k9s &> /dev/null; then
        echo "K9s is already installed."
        return
    fi
    echo "Installing K9s..."
    # Check if the system is Linux
    if [[ "$(uname -s)" == "Linux" ]]; then
        # Download the latest stable version of K9s
        K9S_LATEST_VERSION=$(curl -L -s https://api.github.com/repos/derailed/k9s/releases/latest | grep -oP "tag_name\": \"\K[^\"]+")
        echo "Downloading K9s version ${K9S_LATEST_VERSION}..."
        curl -sSL -o k9s_Linux_x86_64.deb https://github.com/derailed/k9s/releases/download/${K9S_LATEST_VERSION}/k9s_linux_amd64.deb
        sudo dpkg -i k9s_Linux_x86_64.deb
        rm k9s_Linux_x86_64.deb
        # Check if the installation was successful
        if command -v k9s &> /dev/null; then
            echo "K9s installed successfully."
        else
            echo "Failed to install K9s."
            exit 1
        fi
    # Check if the system is macOS
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        # Check if Homebrew is installed
        if command -v brew &> /dev/null; then
            # Install K9s using Homebrew
            brew install derailed/k9s/k9s
            # Check if last command was successful
            if command -v k9s &> /dev/null; then
                echo "K9s installed successfully."
            else
                echo "Failed to install K9s."
                exit 1
            fi
        else
            echo "Homebrew is not installed. Please install Homebrew first."
            exit 1
        fi
    else
        echo "Unsupported operating system. This script only supports Linux and macOS."
        exit 1
    fi
}

# =====================
# Create selection menu
# =====================
echo """
                        @@@                        
                    @@@@@@@@@@@                    
                @@@@@@@@@@@@@@@@@@@                
            @@@@@@@@@@@@@@@@@@@@@@@@@@@            
        @@@@@@@@@@@@@@@@   @@@@@@@@@@@@@@@@        
     @@@@@@@@@@@@@@@@@@@@ @@@@@@@@@@@@@@@@@@@@     
     @@@@@@@@@@@@@@@@@@     @@@@@@@@@@@@@@@@@@     
    @@@@@@@  @@@@@               @@@@@  @@@@@@@    
    @@@@@@@@        @@@@   @@@         @@@@@@@@    
   @@@@@@@@@@@    @@@@@@   @@@@@@    @@@@@@@@@@@   
   @@@@@@@@@@        @@@   @@@        @@@@@@@@@@   
   @@@@@@@@@@  @@@               @@   @@@@@@@@@@   
  @@@@@@@@@@   @@@@@@         @@@@@@   @@@@@@@@@@  
  @@@@@@@@@@   @@@      @@@      @@@   @@@@@@@@@@  
 @@@@@@@@@@@                           @@@@@@@@@@@ 
 @@@@@@         @@@@@@       @@@@@@         @@@@@@ 
 @@@@@@@@@@@@    @@@@   @@@   @@@@    @@@@@@@@@@@@ 
  @@@@@@@@@@@@@   @@   @@@@@   @@    @@@@@@@@@@@@  
   @@@@@@@@@@@@@      @@@@@@@      @@@@@@@@@@@@@   
     @@@@@@@@@@@@@@             @@@@@@@@@@@@@@     
      @@@@@@@@@@@@  @@@@@@@@@@@  @@@@@@@@@@@@      
        @@@@@@@@@  @@@@@@@@@@@@@  @@@@@@@@@        
          @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@          
           @@@@@@@@@@@@@@@@@@@@@@@@@@@@@           
             @@@@@@@@@@@@@@@@@@@@@@@@@             
               @@@@@@@@@@@@@@@@@@@@@               
"""
echo "Welcome to the K8s Bootstrap Script $SUDO_USER!"
options=("Install K3s", "Provision ArgoCD onto Cluster", "Install ArgoCD CLI", "Install K9s", "Exit")
PS3="Please select an option: "
select opt in "${options[@]}"; do
    case $opt in
        "${options[0]}")
            k3s_install
            break
            ;;
        "${options[1]}")
            argocd_k8s_provision
            break
            ;;
        "${options[2]}")
            argocd_cli_install
            break
            ;;
        "${options[3]}")
            k9s_install
            break
            ;;
        "${options[4]}")
            echo "Exiting..."
            break
            ;;
        *)
            echo "Invalid option. Please try again."
            ;;
    esac
done
