#!/usr/bin/env bash
# Topic 3: Cluster Creation
#
# Scenario: build the eksdev cluster from cluster.yaml (15-20 minutes), then check that the
# nodes are Ready, who has access, and which system pods are running.
# Run it inside tmux ("start" joins session "class") so a dropped connection does not stop it.
# Cost: from here on the cluster is billed by the hour. Run Topic 11 after class.

##> Create the EKS cluster (15-20 minutes)
# eksctl builds two CloudFormation stacks: the cluster (with its VPC) and the node group.
cd "$DEMO_HOME"
if aws eks describe-cluster --name "$EKS_CLUSTER_NAME" >/dev/null 2>&1; then
  echo "Cluster $EKS_CLUSTER_NAME already exists - skipping creation."
elif [ ! -f cluster.yaml ]; then
  echo "cluster.yaml not found in $DEMO_HOME - run Topic 2 first (demo 2)."
  false
else
  eksctl create cluster -f cluster.yaml
fi

##> (Optional) Update kubeconfig - eksctl already did this if it just created the cluster
# Needed when the cluster was created earlier or from another machine.
aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION"
kubectl config current-context

##> Verify the cluster
# 3 Ready nodes, the access entries (who may log in), and the system pods.
kubectl get nodes -o wide
aws eks list-access-entries --cluster-name "$EKS_CLUSTER_NAME" --output table
kubectl get pods -A
