#!/usr/bin/env bash
# Topic 2: Cluster Configuration
#
# Scenario: before creating a cluster, you describe it in one file. You write cluster.yaml
# (3 availability zones, a new VPC, 3 m5.large worker nodes, encrypted Secrets, access
# entries) and check it with a dry run. Nothing is created in AWS yet.

##> Set the cluster metadata
# All values are looked up, so the same script works in any account.
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export AWS_REGION=us-west-2
export EKS_CLUSTER_NAME=eksdev
export EKS_VERSION="$(aws eks describe-cluster-versions --default-only --query 'clusterVersions[0].clusterVersion' --output text)"
export MASTER_ARN="$(aws kms describe-key --key-id alias/eksdemo --query KeyMetadata.Arn --output text)"
echo "Account:  ${ACCOUNT_ID}"
echo "Region:   ${AWS_REGION}"
echo "Cluster:  ${EKS_CLUSTER_NAME}  (Kubernetes ${EKS_VERSION})"
echo "KMS key:  ${MASTER_ARN}"

##> Create the cluster configuration file
# What the file asks for:
#   metadata          name, region, Kubernetes version, tags
#   iam.withOIDC      OIDC provider, so pods can get their own IAM roles later
#   vpc               new VPC 10.42.0.0/16; API endpoint reachable publicly and from inside
#   secretsEncryption Kubernetes Secrets encrypted with the Topic 1 KMS key
#   accessConfig      access entries (API mode); the creator (this instance role) is admin
#   addons.vpc-cni    pod networking, with prefix delegation and network policies on
#   managedNodeGroups 3 x m5.large in private subnets (can grow to 6)
mkdir -p "$DEMO_HOME" && cd "$DEMO_HOME"
cat << EOF > cluster.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
availabilityZones:
  - ${AWS_REGION}a
  - ${AWS_REGION}b
  - ${AWS_REGION}c
metadata:
  name: ${EKS_CLUSTER_NAME}
  region: ${AWS_REGION}
  version: "${EKS_VERSION}"
  tags:
    karpenter.sh/discovery: ${EKS_CLUSTER_NAME}
    created-by: eks-workshop-v2
    env: ${EKS_CLUSTER_NAME}
iam:
  withOIDC: true
vpc:
  cidr: 10.42.0.0/16
  clusterEndpoints:
    privateAccess: true
    publicAccess: true
secretsEncryption:
  keyARN: ${MASTER_ARN}
accessConfig:
  authenticationMode: API
  bootstrapClusterCreatorAdminPermissions: true
addons:
  - name: vpc-cni
    configurationValues: '{"env":{"ENABLE_PREFIX_DELEGATION":"true", "ENABLE_POD_ENI":"true", "POD_SECURITY_GROUP_ENFORCING_MODE":"standard"},"enableNetworkPolicy": "true", "nodeAgent": {"enablePolicyEventLogs": "true"}}'
    resolveConflicts: overwrite
managedNodeGroups:
  - name: default
    desiredCapacity: 3
    minSize: 3
    maxSize: 6
    instanceType: m5.large
    privateNetworking: true
    updateConfig:
      maxUnavailablePercentage: 50
    labels:
      workshop-default: "yes"
EOF
cat cluster.yaml

##> Validate the configuration (dry run - creates nothing)
# eksctl reads the file, fills in defaults and prints the full plan without calling AWS.
eksctl create cluster -f cluster.yaml --dry-run > /tmp/cluster-dry-run.yaml && echo "cluster.yaml is valid (full plan in /tmp/cluster-dry-run.yaml)"
