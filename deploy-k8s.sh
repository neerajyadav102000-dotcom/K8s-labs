#!/bin/bash
set -e

AMI_ID="ami-04d521ceaa4be5798"
INSTANCE_TYPE="c7i-flex.large"
KEY_NAME="DEVOPS"
PEM_FILE="$HOME/.ssh/ABC.pem"
SG_ID="sg-0bec49023f14a0220"
SUBNET_ID="subnet-04b7f9243b17e8862"
K8S_VERSION="v1.31"
CALICO_VERSION="v3.28.2"

echo "=== 1. Launching 1 Master & 2 Worker EC2 Instances ==="
MASTER_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID --instance-type $INSTANCE_TYPE --count 1 \
  --key-name $KEY_NAME --security-group-ids $SG_ID --subnet-id $SUBNET_ID \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":20,"VolumeType":"gp3"}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=k8s-master},{Key=Project,Value=k8s-lab}]' \
  --query "Instances[0].InstanceId" --output text)

WORKER_IDS=$(aws ec2 run-instances \
  --image-id $AMI_ID --instance-type $INSTANCE_TYPE --count 2 \
  --key-name $KEY_NAME --security-group-ids $SG_ID --subnet-id $SUBNET_ID \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":20,"VolumeType":"gp3"}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=k8s-worker},{Key=Project,Value=k8s-lab}]' \
  --query "Instances[*].InstanceId" --output text)

W1_ID=$(echo $WORKER_IDS | awk '{print $1}')
W2_ID=$(echo $WORKER_IDS | awk '{print $2}')

aws ec2 create-tags --resources $W1_ID --tags Key=Name,Value=k8s-worker-1
aws ec2 create-tags --resources $W2_ID --tags Key=Name,Value=k8s-worker-2

echo "Waiting for instances to enter running state..."
aws ec2 wait instance-running --instance-ids $MASTER_ID $W1_ID $W2_ID

MASTER_IP=$(aws ec2 describe-instances --instance-ids $MASTER_ID --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)
W1_IP=$(aws ec2 describe-instances --instance-ids $W1_ID --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)
W2_IP=$(aws ec2 describe-instances --instance-ids $W2_ID --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)

cat <<INST > ~/k8s-cluster-iac/cluster-state.env
MASTER_ID=$MASTER_ID
W1_ID=$W1_ID
W2_ID=$W2_ID
MASTER_IP=$MASTER_IP
W1_IP=$W1_IP
W2_IP=$W2_IP
INST

echo "Nodes Ready -> Master: $MASTER_IP ($MASTER_ID) | Worker1: $W1_IP ($W1_ID) | Worker2: $W2_IP ($W2_ID)"
echo "Waiting 25s for SSH daemon..."
sleep 25

# Common Node Prerequisite Setup Function
setup_node() {
  local NODE_IP=$1
  local HOSTNAME=$2
  echo "=== Configuring Prerequisites on $HOSTNAME ($NODE_IP) ==="
  ssh -o StrictHostKeyChecking=no -i $PEM_FILE ec2-user@$NODE_IP bash -s <<REMOTE
set -e
sudo hostnamectl set-hostname $HOSTNAME
cat <<HOSTS | sudo tee -a /etc/hosts
$MASTER_IP k8s-master K8s-master
$W1_IP k8s-worker-1
$W2_IP k8s-worker-2
HOSTS
sudo swapoff -a && sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
cat <<MOD | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
MOD
sudo modprobe overlay && sudo modprobe br_netfilter
cat <<SYS | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYS
sudo sysctl --system >/dev/null
sudo mkdir -p /etc/containerd && containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo systemctl enable --now containerd && sudo systemctl restart containerd
cat <<REPO | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
REPO
sudo dnf install -y conntrack-tools iproute-tc kubelet kubeadm kubectl --disableexcludes=kubernetes
sudo systemctl enable kubelet
REMOTE
}

setup_node $MASTER_IP "k8s-master"
setup_node $W1_IP "k8s-worker-1"
setup_node $W2_IP "k8s-worker-2"

echo "=== 2. Initializing Control Plane on k8s-master ($MASTER_IP) ==="
ssh -o StrictHostKeyChecking=no -i $PEM_FILE ec2-user@$MASTER_IP bash -s <<MASTER_INIT
set -e
sudo kubeadm config images pull
sudo kubeadm init --apiserver-advertise-address=$MASTER_IP --pod-network-cidr=192.168.0.0/16
mkdir -p \$HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config
sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/calico.yaml
MASTER_INIT

JOIN_CMD=$(ssh -o StrictHostKeyChecking=no -i $PEM_FILE ec2-user@$MASTER_IP "sudo kubeadm token create --print-join-command")

echo "=== 3. Joining Worker Nodes ==="
ssh -o StrictHostKeyChecking=no -i $PEM_FILE ec2-user@$W1_IP "sudo $JOIN_CMD"
ssh -o StrictHostKeyChecking=no -i $PEM_FILE ec2-user@$W2_IP "sudo $JOIN_CMD"

echo "=== 4. Syncing kubeconfig to Jump Server & Labeling Workers ==="
mkdir -p ~/.kube
scp -o StrictHostKeyChecking=no -i $PEM_FILE ec2-user@$MASTER_IP:~/.kube/config ~/.kube/config
chmod 600 ~/.kube/config
kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl label node k8s-worker-1 k8s-worker-2 node-role.kubernetes.io/worker=worker --overwrite
kubectl get nodes -o wide
