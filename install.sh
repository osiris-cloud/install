#!/bin/bash

print_color() {
  local color_code
  case "$2" in
      "red")     color_code="0;31" ;;
      "green")   color_code="0;32" ;;
      "yellow")  color_code="0;33" ;;
      "magenta") color_code="0;35" ;;
      "cyan")    color_code="0;36" ;;
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
      --node-ip) NODE_IP="$2"; shift ;;
      *) print_color "Unknown parameter: $1" "red"; print_usage ;;
  esac
  shift
done

# Validate the role
if [ "$ROLE" != "controller" ] && [ "$ROLE" != "worker" ] && [ "$ROLE" != "lb" ]; then
  print_color "Invalid role. Must be either 'controller' or 'worker'." "red"
  print_usage
fi

# If worker, ensure token and controller IP are provided
if [ "$ROLE" == "worker" ]; then
  if [ -z "$TOKEN" ] || [ -z "$CONTROLLER_IP" ]; then
      print_color "For worker role, both --token and --controller-ip must be provided." "red"
      print_usage
  fi

elif [ "$ROLE" == "lb" ]; then
  if [ -z "$NODE_IP" ]; then
      print_color "For lb role, --node-ip must be provided." "red"
      print_usage
  fi
fi

install_cloud_dep() {
  systemctl daemon-reload > /dev/null
  # Disable systemd resolved
  systemctl stop systemd-resolved > /dev/null
  systemctl disable systemd-resolved > /dev/null
  rm -f /etc/resolv.conf > /dev/null
  printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf

  print_color "\xE2\x9C\x94  Disabled systemd resolved" "green"
  print_color "\xE2\x9C\x94  Default DNS set to 1.1.1.1 and 8.8.8.8" "cyan"

  swapoff -a
  sed -i '/\sswap\s/s/^/#/' /etc/fstab

  print_color "\xE2\x9C\x94  Swap turned off" "green"

  cat << EOF | tee /etc/modules-load.d/k8s.conf > /dev/null
overlay
br_netfilter
EOF

  modprobe overlay
  modprobe br_netfilter

  print_color "\xE2\x9C\x94  Added overlay and netfilter modules" "green"

  cat <<EOF | tee /etc/sysctl.d/k8s.conf > /dev/null
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
}

generate_haproxy_config() {
  local node_ips=("$@")
  local backend_config=""

  for i in "${!node_ips[@]}"; do
      node_num=$((i + 1))
      # HTTP backend entries
      backend_http+="server node${node_num} ${node_ips[$i]}:30000 send-proxy check\n"
      # HTTPS backend entries
      backend_https+="server node${node_num} ${node_ips[$i]}:30001 send-proxy check\n"
  done

  cat << EOF | tee /etc/haproxy/haproxy.cfg > /dev/null
#---------------------------------------------------------------------
# Global settings
#---------------------------------------------------------------------
global
    log         127.0.0.1 local2

    chroot      /var/lib/haproxy
    pidfile     /var/run/haproxy.pid
    maxconn     10000
    user        haproxy
    group       haproxy
    daemon

    # turn on stats unix socket
    stats socket /var/lib/haproxy/stats

    # utilize system-wide crypto-policies
    ssl-default-bind-ciphers PROFILE=SYSTEM
    ssl-default-server-ciphers PROFILE=SYSTEM

#---------------------------------------------------------------------
# common defaults that all the 'listen' and 'backend' sections will
#---------------------------------------------------------------------
defaults
    mode                    tcp
    log                     global
    option                  tcplog
    option                  dontlognull

    timeout queue           1m
    timeout connect         10s
    timeout client          1m
    timeout server          1m
    timeout check           10s
    maxconn                 10000

frontend http-in
    bind *:80
    mode tcp
    option tcplog  # Preserve source IP
    default_backend http-backend

frontend https-in
    bind *:443
    mode tcp
    option tcplog  # Preserve source IP
    default_backend https-backend

backend http-backend
    balance source
    mode tcp
    option tcp-check
    $(echo -e "$backend_http")

backend https-backend
    balance source
    mode tcp
    option tcp-check
    $(echo -e "$backend_https")
EOF
}

## Control Plane
if [ "$ROLE" == "controller" ]; then

  install_cloud_dep

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
  kubectl apply -f https://raw.githubusercontent.com/kata-containers/kata-containers/stable-3.2/tools/packaging/kata-deploy/kata-rbac/base/kata-rbac.yaml > /dev/null
  sleep 5
  kubectl apply -f https://raw.githubusercontent.com/kata-containers/kata-containers/stable-3.2/tools/packaging/kata-deploy/kata-deploy/base/kata-deploy.yaml > /dev/null
  kubectl -n kube-system wait --timeout=5m --for=condition=Ready -l name=kata-deploy pod > /dev/null
  kubectl apply -f https://raw.githubusercontent.com/kata-containers/kata-containers/main/tools/packaging/kata-deploy/runtimeclasses/kata-runtimeClasses.yaml > /dev/null
  print_color "\xE2\x9C\x94  CRI installed" "green"

  print_color "Initializing Ingress Controller" "cyan"
  kubectl apply -f https://raw.githubusercontent.com/osiris-cloud/install/refs/heads/main/ingress-controller.yaml > /dev/null
  print_color "\xE2\x9C\x94  Ingress Controller installed" "green"

  WORKER_TOKEN=$(kubeadm token create --print-join-command | awk '{print $5}')
  MY_IP=$(ip -o -4 addr show | grep -v ' lo ' | awk '{print $4}' | head -n 1 | cut -d/ -f1)

  print_color "\xE2\x9C\x94  Osiris Controller node is ready" "green"
  print_color "Run the following on worker nodes" "cyan"
  print_color "curl -sSL https://raw.githubusercontent.com/osiris-cloud/install/refs/heads/main/install.sh | bash -s -- --role worker --token $WORKER_TOKEN --controller-ip $MY_IP" "magenta"
  echo ""

  print_color "Run this after you have bootstrapped your cluster to block subsequent worker node registrations" "yellow"
  print_color " kubectl delete clusterrolebinding kubeadm:node-autoapprove-bootstrap" "yellow"

elif [ "$ROLE" == "worker" ]; then
  install_cloud_dep
  kubeadm join $CONTROLLER_IP:6443 --token $TOKEN --cri-socket unix:///var/run/crio/crio.sock --discovery-token-unsafe-skip-ca-verification > /dev/null

elif [ "$ROLE" == "lb" ]; then
  print_color "Installing docker..." "cyan"

  dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo > /dev/null
  dnf install -y docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin > /dev/null
  systemctl enable docker --now

  print_color "\xE2\x9C\x94  Docker service enabled" "green"

  interfaces=($(ls /sys/class/net | grep -v lo))
  cat << EOF | tee /etc/systemd/system/promisc-mode.service > /dev/null
[Unit]
Description=Enable promiscuous mode on ${interfaces[0]} and ${interfaces[1]}

[Service]
Type=oneshot
ExecStart=/usr/sbin/ip link set ${interfaces[0]} promisc on
ExecStart=/usr/sbin/ip link set ${interfaces[1]} promisc on

[Install]
WantedBy=multi-user.target
EOF

  print_color "\xE2\x9C\x94  Promisc mode enabled on ${interfaces[0]}, ${interfaces[1]}" "green"
  print_color "Configuring firewall rules..." "cyan"

  systemctl daemon-reload
  systemctl enable --now promisc-mode.service > /dev/null

  firewall-cmd --zone=internal --add-interface="${interfaces[0]}" --permanent
  firewall-cmd --zone=internal --add-forward --permanent

  firewall-cmd --zone=internal --add-rich-rule='rule family="ipv4" source address="0.0.0.0/0" accept' --permanent
  firewall-cmd --zone=internal --add-rich-rule='rule family="ipv6" source address="::/0" accept' --permanent

  firewall-cmd --reload

  firewall-cmd --permanent --new-zone=public_int
  firewall-cmd --zone=public_int --add-interface=ens224 --permanent
  firewall-cmd --zone=public_int --add-forward --permanent

  firewall-cmd --zone=public_int --add-rich-rule='rule family=ipv4 port port=11111 protocol=tcp reject' --permanent
  firewall-cmd --zone=public_int --add-rich-rule='rule family=ipv4 port port=11111 protocol=udp reject' --permanent

  # block ssh
  firewall-cmd --zone=public_int --add-rich-rule='rule family=ipv4 port port=22 protocol=tcp reject' --permanent

  firewall-cmd --reload

  print_color "\xE2\x9C\x94  Firewall rules active" "green"
  print_color "- Deny tcp port 11111 on public network" "cyan"
  print_color "- Deny tcp and udp port 22 on public network" "cyan"
  print_color "- Allow tcp and udp * on public network" "cyan"
  echo ""

  print_color "Starting TCP/UDP service load balancer" "cyan"
  docker run -u root --cap-add SYS_ADMIN --net=host --restart unless-stopped --privileged -dit -v /dev/log:/dev/log --name loxilb ghcr.io/loxilb-io/loxilb:latest > /dev/null

  print_color "\xE2\x9C\x94  Common Service Load balancer started" "green"

  print_color "Installing HAProxy..." "cyan"
  dnf install -y haproxy

  setcap 'cap_net_bind_service=+ep' /usr/sbin/haproxy

  cat << EOF | tee /etc/firewalld/services/haproxy-http.xml > /dev/null
<?xml version="1.0" encoding="utf-8"?>
<service>
<short>HAProxy-HTTP</short>
<description>HAProxy load-balancer</description>
<port protocol="tcp" port="80"/>
</service>
EOF

  cat << EOF | tee /etc/firewalld/services/haproxy-https.xml > /dev/null
<?xml version="1.0" encoding="utf-8"?>
<service>
<short>HAProxy-HTTPS</short>
<description>HAProxy load-balancer</description>
<port protocol="tcp" port="443"/>
</service>
EOF

  restorecon haproxy-http.xml
  chmod 640 haproxy-http.xml

  restorecon haproxy-https.xml
  chmod 640 haproxy-https.xml

  print_color "Generating HAProxy config..." "cyan"
  IFS=',' read -ra IP_ARRAY <<< "$NODE_IP"
  generate_haproxy_config "${IP_ARRAY[@]}"

  if haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1; then
      print_color "\xE2\x9C\x94  HAProxy config is valid" "green"
  else
      print_color "HAProxy error. Stop" "red"
      exit 1
  fi

  print_color "Starting HAProxy TCP proxy load balancer" "cyan"
  systemctl enable haproxy --now > /dev/null

  print_color "\xE2\x9C\x94  HAProxy started" "green"

fi
