provider "aws" {
  region = "ap-south-1"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_instance" "K8s_master" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "c7i-flex.large"
  key_name                    = "DEVOPS"
  vpc_security_group_ids      = ["sg-079e9d05fd359830c"]
  user_data_replace_on_change = true

  root_block_device {
    volume_size = 30
  }

  user_data = <<-EOT
    #!/bin/bash
    set -e
    exec > /var/log/k8s-setup.log 2>&1

    # 1. Jump server public key add karein
    echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDLbfOnn7f8uTDogjkbhZuq6+6DZ8d5d00TekUvIiA3sdj1AjSGq98H+kySEZx1gyE212Vuow6y9KW9MYjEBK7AyvOpOEOcg5EwymX8fLyGJ9vAV/uCWxMq/oEgmA8O2bXw9bzMKD9rvr5SgFYn3iInRu1OQ2JXKKAmkAhbbIWBJtJ6GwNUHQEaT/brMJvVe2V2m39EPk6ig7CeFjGUyVYLyjR8y7RwJlZ4XAs53GtEHEXS+uSoITfBbDuQD/JC1guZadm9gjY5QXKt9rudxMc8emuGijg6aIJ9Fe4sJpQd99RIe1er2bv1F9olC6x9uBulnAfzFcWHSsRUNBwiYVZB" >> /home/ubuntu/.ssh/authorized_keys
    chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys
    chmod 600 /home/ubuntu/.ssh/authorized_keys

    # 2. Swap disable karein
    swapoff -a
    sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

    # 3. Kernel modules aur sysctl settings
    cat <<EOF > /etc/modules-load.d/k8s.conf
    overlay
    br_netfilter
    EOF
    modprobe overlay
    modprobe br_netfilter

    cat <<EOF > /etc/sysctl.d/k8s.conf
    net.bridge.bridge-nf-call-iptables  = 1
    net.bridge.bridge-nf-call-ip6tables = 1
    net.ipv4.ip_forward                 = 1
    EOF
    sysctl --system

    # 4. containerd, conntrack aur dependencies install karein
    apt-get update
    apt-get install -y containerd conntrack apt-transport-https ca-certificates curl gpg
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    systemctl restart containerd
    systemctl enable containerd

    # 5. kubelet, kubeadm, kubectl (v1.31) install karein
    mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
    apt-get update
    apt-get install -y kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl

    # 6. Cluster initialize karein
    PRIVATE_IP=$(hostname -I | awk '{print $1}')
    kubeadm init --pod-network-cidr=192.168.0.0/16 --apiserver-advertise-address=$PRIVATE_IP

    # 7. kubectl config set karein
    mkdir -p /home/ubuntu/.kube
    cp -i /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
    chown -R ubuntu:ubuntu /home/ubuntu/.kube

    # 8. Calico CNI install karein
    su - ubuntu -c "kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml"

    # 9. Worker join command save karein
    kubeadm token create --print-join-command > /home/ubuntu/join-command.sh
    chmod +x /home/ubuntu/join-command.sh
    chown ubuntu:ubuntu /home/ubuntu/join-command.sh
  EOT

  tags = {
    Name = "K8s-master_node"
  }
}

output "master_public_ip" {
  value = aws_instance.K8s_master.public_ip
}

output "master_private_ip" {
  value = aws_instance.K8s_master.private_ip
}
