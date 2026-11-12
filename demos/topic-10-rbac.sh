#!/usr/bin/env bash
# Topic 10: RBAC Configuration
#
# Scenario: a new team member may look at the app in one namespace, but must not change
# anything or look anywhere else. You create an IAM user (rbac-user), map it into the
# cluster, give it read-only access to the rbac-test namespace, and test what it can do.
#   IAM user + key -> EKS access entry -> Role + RoleBinding -> test as admin
#   -> test as rbac-user -> back to admin -> clean up

##> Create the test namespace and deployment
# rbac-test is the only namespace rbac-user will be allowed to read.
cd "$DEMO_HOME"
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
kubectl create namespace rbac-test --dry-run=client -o yaml | kubectl apply -f -
kubectl create deploy nginx --image=nginx -n rbac-test --dry-run=client -o yaml | kubectl apply -f -
kubectl get all -n rbac-test

##> Create the IAM user and an access key
# The user has no IAM policies: it can only log in. Kubernetes RBAC decides what it may do.
aws iam create-user --user-name rbac-user
# The key goes to a file, so the secret is never shown on screen.
aws iam create-access-key --user-name rbac-user > /tmp/create_output.json
echo "Created access key $(jq -r .AccessKey.AccessKeyId /tmp/create_output.json) (secret not shown)"

##> Capture the credentials
# Writes the two exports to rbacuser_creds.sh (readable only by you). Step 9 sources it.
cat << EOF > rbacuser_creds.sh
export AWS_SECRET_ACCESS_KEY=$(jq -r .AccessKey.SecretAccessKey /tmp/create_output.json)
export AWS_ACCESS_KEY_ID=$(jq -r .AccessKey.AccessKeyId /tmp/create_output.json)
EOF
chmod 600 rbacuser_creds.sh
ls -l rbacuser_creds.sh

##> Map the IAM user into the cluster (EKS access entry)
# An access entry tells EKS: this IAM ARN is Kubernetes user "rbac-user".
# No access policy is attached, so the user has no rights until the RoleBinding below.
# Wait first: a brand-new IAM user is not visible to EKS for a few seconds.
sleep 15
aws eks create-access-entry --cluster-name "$EKS_CLUSTER_NAME" --principal-arn "arn:aws:iam::${ACCOUNT_ID}:user/rbac-user" --username rbac-user
aws eks list-access-entries --cluster-name "$EKS_CLUSTER_NAME" --output table

##> Create the RBAC role
# Role = WHAT is allowed, in one namespace: read (get/list/watch) pods and deployments.
cat << 'EOF' > rbacuser-role.yaml
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  namespace: rbac-test
  name: pod-reader
rules:
- apiGroups: [""] # "" indicates the core API group
  resources: ["pods"]
  verbs: ["list","get","watch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch"]
EOF
cat rbacuser-role.yaml

##> Create the role binding
# RoleBinding = WHO gets the Role. The name must match --username from the access entry.
cat << 'EOF' > rbacuser-role-binding.yaml
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: read-pods
  namespace: rbac-test
subjects:
- kind: User
  name: rbac-user
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
EOF
cat rbacuser-role-binding.yaml

##> Apply the RBAC configuration
kubectl apply -f rbacuser-role.yaml
kubectl apply -f rbacuser-role-binding.yaml

##> Test as the instance role (admin): sees everything
# The workstation's instance role has cluster admin, so all three namespaces work.
aws sts get-caller-identity --query Arn --output text
kubectl get pods -n rbac-test
kubectl get pods -n default
kubectl get pods -n kube-system

##> Switch to rbac-user
# Sourcing the file exports rbac-user's keys in YOUR shell. Environment keys win over
# the instance role, so every aws and kubectl command now runs as rbac-user.
# The pause gives a new access key time to become active (IAM is eventually consistent).
cd "$DEMO_HOME"
source ./rbacuser_creds.sh
sleep 15
# Should print .../user/rbac-user
aws sts get-caller-identity --query Arn --output text

##> Test as rbac-user: everything outside the Role is FORBIDDEN
# Other namespaces and the delete verb are not in the Role, so each command is denied.
# "|| true": the error is expected, so the step still counts as done.
kubectl get pods -n default
kubectl get pods -n kube-system
kubectl delete deploy nginx -n rbac-test || true

##> Test as rbac-user: reading in rbac-test WORKS
kubectl get pods -n rbac-test
kubectl get deployments -n rbac-test

##> Switch back to the instance role
# Removing the keys makes the CLI fall back to the instance role (admin) again.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
aws sts get-caller-identity --query Arn --output text
kubectl get pods -n kube-system

##> Clean up RBAC (back to the state before this topic)
# Run as admin. Deleting the namespace also removes nginx, the Role and the RoleBinding.
# Only rbac-user's access entry is deleted; the other entries are left alone.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
cd "$DEMO_HOME"
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
kubectl delete namespace rbac-test --ignore-not-found
aws eks delete-access-entry --cluster-name "$EKS_CLUSTER_NAME" --principal-arn "arn:aws:iam::${ACCOUNT_ID}:user/rbac-user"
aws iam delete-access-key --user-name rbac-user --access-key-id "$(jq -r .AccessKey.AccessKeyId /tmp/create_output.json)"
aws iam delete-user --user-name rbac-user
rm -f rbacuser_creds.sh rbacuser-role.yaml rbacuser-role-binding.yaml /tmp/create_output.json
# Expect 3 access entries left (EKS service role, instance role, node role) and no rbac-test.
aws eks list-access-entries --cluster-name "$EKS_CLUSTER_NAME" --output table
kubectl get namespaces
