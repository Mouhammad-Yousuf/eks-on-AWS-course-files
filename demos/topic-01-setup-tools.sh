#!/usr/bin/env bash
# Topic 1: Initial Setup and Tool Installation
#
# Scenario: a fresh workstation needs the tools to build and manage an EKS cluster.
# You install or update kubectl, the AWS CLI, eksctl and yq, turn on TAB completion,
# create the ~/environment workspace and a KMS key that encrypts Kubernetes Secrets.

##> Check which tools are already installed
for command in aws kubectl eksctl helm docker jq yq envsubst git; do
  if command -v "$command" >/dev/null 2>&1; then
    echo "OK       $command -> $(command -v "$command")"
  else
    echo "MISSING  $command"
  fi
done

##> Install or update kubectl (same minor version as the EKS default)
# Ask EKS for its default Kubernetes version, then download the latest kubectl patch for it.
# kubectl supports one minor version above and below the cluster.
EKS_DEFAULT_VERSION="$(aws eks describe-cluster-versions --default-only --query 'clusterVersions[0].clusterVersion' --output text)"
KUBECTL_VERSION="$(curl -fsSL "https://dl.k8s.io/release/stable-${EKS_DEFAULT_VERSION}.txt")"
echo "EKS default: ${EKS_DEFAULT_VERSION}  ->  kubectl ${KUBECTL_VERSION}"
sudo curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
sudo chmod +x /usr/local/bin/kubectl
kubectl version --client

##> Update the AWS CLI v2
# Download the official installer to /tmp; --update replaces an existing install in place.
# hash -r makes the shell forget the old path to "aws".
cd /tmp
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
rm -rf aws && unzip -q awscliv2.zip
sudo ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update
rm -rf aws awscliv2.zip
cd ~
hash -r
aws --version

##> Install required utilities
# jq = JSON, gettext = envsubst, bash-completion = TAB completion for kubectl/eksctl.
sudo dnf -y install jq gettext bash-completion git tar unzip

##> Install yq for YAML processing
sudo curl -fsSL -o /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq
yq --version

##> Install or update eksctl
# eksctl creates and deletes the cluster (Topics 3 and 11) using CloudFormation.
curl -fsSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar -xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin/eksctl
eksctl version

##> Verify the binaries are on the PATH
for command in kubectl jq envsubst aws eksctl yq; do
  command -v "$command" >/dev/null 2>&1 && echo "$command in path" || echo "$command NOT FOUND"
done

##> Enable kubectl and eksctl bash completion
# Added to ~/.bashrc once (for new terminals) and loaded now (for this one).
# Also adds the alias k=kubectl with the same completion.
grep -q 'kubectl completion bash' ~/.bashrc || echo 'source <(kubectl completion bash); alias k=kubectl; complete -o default -F __start_kubectl k' >> ~/.bashrc
grep -q 'eksctl completion bash' ~/.bashrc || echo 'source <(eksctl completion bash)' >> ~/.bashrc
source <(kubectl completion bash)
source <(eksctl completion bash)
echo "Completion enabled. Try: kubectl get <TAB><TAB>"

##> Create the workspace and clone the sample service repos (optional)
# Every topic writes its files under ~/environment. Existing clones are skipped.
mkdir -p "$DEMO_HOME" && cd "$DEMO_HOME"
for repo in ecsdemo-frontend ecsdemo-nodejs ecsdemo-crystal; do
  [ -d "$repo" ] || git clone -q "https://github.com/aws-containers/${repo}.git"
done
ls -l

##> Create a KMS key for EKS secrets encryption (re-uses it if it exists)
# EKS uses this key to encrypt Kubernetes Secrets at rest (cluster.yaml, Topic 2).
# A new key is made only if alias/eksdemo is missing or points at a disabled key.
# MASTER_ARN is saved in ~/.bashrc so new terminals have it.
if ! aws kms describe-key --key-id alias/eksdemo --query 'KeyMetadata.KeyState' --output text 2>/dev/null | grep -q Enabled; then
  aws kms delete-alias --alias-name alias/eksdemo 2>/dev/null || true
  KEY_ARN="$(aws kms create-key --description "EKS demo secrets encryption" --query KeyMetadata.Arn --output text)"
  aws kms create-alias --alias-name alias/eksdemo --target-key-id "$KEY_ARN"
fi
export MASTER_ARN="$(aws kms describe-key --key-id alias/eksdemo --query KeyMetadata.Arn --output text)"
grep -q 'export MASTER_ARN=' ~/.bashrc || echo "export MASTER_ARN=${MASTER_ARN}" >> ~/.bashrc
echo "MASTER_ARN=${MASTER_ARN}"
