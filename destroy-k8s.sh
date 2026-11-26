#!/bin/bash
set -e

if [ ! -f ~/k8s-cluster-iac/cluster-state.env ]; then
  echo "cluster-state.env not found! Checking AWS by tag Project=k8s-lab..."
  IDS=$(aws ec2 describe-instances --filters "Name=tag:Project,Values=k8s-lab" "Name=instance-state-name,Values=running,stopped" --query "Reservations[*].Instances[*].InstanceId" --output text)
else
  source ~/k8s-cluster-iac/cluster-state.env
  IDS="$MASTER_ID $W1_ID $W2_ID"
fi

if [ -z "$IDS" ]; then
  echo "No active cluster instances found."
  exit 0
fi

echo "Terminating instances: $IDS"
aws ec2 terminate-instances --instance-ids $IDS
aws ec2 wait instance-terminated --instance-ids $IDS
rm -f ~/k8s-cluster-iac/cluster-state.env ~/.kube/config
echo "Cluster cleanly destroyed!"
