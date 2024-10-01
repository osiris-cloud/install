#!/bin/bash

print_color() {
    local color_code
    case "$2" in
        "red")     color_code="0;31" ;;
        "green")   color_code="0;32" ;;
        "yellow")  color_code="0;33" ;;
        "blue")    color_code="0;34" ;;
        "magenta") color_code="0;35" ;;
        "cyan")    color_code="0;36" ;;
        "white")   color_code="0;37" ;;
        *)         color_code="0" ;;
    esac
    echo -e "\e[${color_code}m${1}\e[0m"
}

# Function to print usage
print_usage() {
    print_color "Usage:" "cyan"
    print_color "  * For controller: $0 --role controller" "cyan"
    print_color "  * For worker: $0 --role worker --token <token> --controller-ip <ip>" "cyan"
    exit 1
}

# Check if the minimum number of arguments is provided
if [ "$#" -lt 2 ]; then
    print_usage
fi

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --role) ROLE="$2"; shift ;;
        --token) TOKEN="$2"; shift ;;
        --controller-ip) CONTROLLER_IP="$2"; shift ;;
        *) print_color "Unknown parameter: $1" "red"; print_usage ;;
    esac
    shift
done

# Validate the role
if [ "$ROLE" != "controller" ] && [ "$ROLE" != "worker" ]; then
    print_color "Invalid role. Must be either 'controller' or 'worker'." "red"
    print_usage
fi

# If worker, ensure token and controller IP are provided
if [ "$ROLE" == "worker" ]; then
    if [ -z "$TOKEN" ] || [ -z "$CONTROLLER_IP" ]; then
        print_color "For worker role, both --token and --controller-ip must be provided." "red"
        print_usage
    fi
fi

# Disable systemd resolved

systemctl daemon-reload > /dev/null
systemctl stop systemd-resolved > /dev/null
systemctl disable systemd-resolved > /dev/null
rm -f /etc/resolv.conf > /dev/null
printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf

print_color "\xE2\x9C\x94  Disabled systemd resolved" "green"
print_color "\xE2\x9C\x94  Default DNS set to 1.1.1.1 and 8.8.8.8" "cyan"

swapoff -a
sed -i '/\sswap\s/s/^/#/' /etc/fstab

print_color "\xE2\x9C\x94  Swap turned off" "green"

cat << EOF | sudo tee /etc/modules-load.d/k8s.conf > /dev/null
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

print_color "\xE2\x9C\x94  Added overlay and netfilter modules" "green"

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf > /dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

print_color "\xE2\x9C\x94  Enabled IPv6" "green"

sysctl -w net.ipv4.ip_forward=1 > /dev/null

print_color "\xE2\x9C\x94  Enabled network forewarding" "green"

systemctl disable firewalld --now > /dev/null

print_color "\xE2\x9C\x94  Disabled Firewall" "green"

dnf install -y NetworkManager NetworkManager-tui > /dev/null

systemctl daemon-reload > /dev/null

print_color "Installing Kubernetes dependencies" "cyan"

# For CRI
dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo > /dev/null
dnf install -y docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin > /dev/null
dnf install -y containernetworking-plugins container-selinux selinux-policy-base crio iproute-tc > /dev/null
dnf install -y kubernetes kubernetes-kubeadm kubernetes-client > /dev/null
systemctl enable --now kubelet docker crio > /dev/null
print_color "\xE2\x9C\x94  Installed Container Runtime dependencies" "green"

# For CSI

yum --setopt=tsflags=noscripts install iscsi-initiator-utils nfs-utils
echo "InitiatorName=$(/sbin/iscsi-iname)" > /etc/iscsi/initiatorname.iscsi
systemctl enable iscsid > /dev/null
modprobe iscsi_tcp > /dev/null
systemctl start iscsid > /dev/null
print_color "\xE2\x9C\x94  Installed Container Storage dependencies" "green"

## Control Plane

if [ "$ROLE" == "controller" ]; then 

    curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

    print_color "Initializing Controller" "cyan"
    kubeadm init --cri-socket unix:///var/run/crio/crio.sock --pod-network-cidr=10.244.0.0/16 > /dev/null
    print_color "\xE2\x9C\x94  Initialized Kubeternetes" "green"

    mkdir -p $HOME/.kube > /dev/null
    cp -i /etc/kubernetes/admin.conf $HOME/.kube/config > /dev/null
    chown $(id -u):$(id -g) $HOME/.kube/config > /dev/null
    print_color "kubeconfig saved to ~/.kube/config" "cyan"

    print_color "Waiting for cluster to be ready..." "yellow"
    sleep 20

    print_color "Initializing Container Networking Interface" "cyan"
    CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/master/stable.txt)
    curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz
    tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin > /dev/null
    rm -f cilium-linux-amd64.tar.gz > /dev/null
    cilium install > /dev/null
    print_color "\xE2\x9C\x94  CNI installed" "green"

    print_color "Waiting for cluster to be ready..." "yellow"
    sleep 20

    print_color "Initializing Container Runtime Interface" "cyan"
    kubectl apply -f https://raw.githubusercontent.com/kata-containers/kata-containers/stable-3.2/tools/packaging/kata-deploy/kata-rbac/base/kata-rbac.yaml
    kubectl apply -f https://raw.githubusercontent.com/kata-containers/kata-containers/stable-3.2/tools/packaging/kata-deploy/kata-deploy/base/kata-deploy.yaml
    kubectl -n kube-system wait --timeout=5m --for=condition=Ready -l name=kata-deploy pod > /dev/null
    kubectl apply -f https://raw.githubusercontent.com/kata-containers/kata-containers/main/tools/packaging/kata-deploy/runtimeclasses/kata-runtimeClasses.yaml
    print_color "\xE2\x9C\x94  CRI installed" "green"

    kubectl apply -f <Ingess url>

    WORKER_TOKEN=$(kubeadm token create --print-join-command | awk '{print $5}')

    print_color "\xE2\x9C\x94  Controller is Ready" "green"

    print_color "Run the following command on worker nodes" "magenta"

fi




