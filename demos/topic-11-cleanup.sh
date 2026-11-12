#!/usr/bin/env bash
# Topic 11: Cleanup Procedures
#
# Scenario: class is over. Remove everything Topics 4-10 created (newest first), check that
# no load balancers are left, then optionally delete the cluster and the KMS key.

##> Clean up RBAC (Topic 10)
# Become admin again first, in case the rbac-user keys are still exported.
# Deleting the namespace removes the nginx deployment, Role and RoleBinding.
unset AWS_SECRET_ACCESS_KEY AWS_ACCESS_KEY_ID
cd "$DEMO_HOME"
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
kubectl delete namespace rbac-test --ignore-not-found
aws eks delete-access-entry --cluster-name "$EKS_CLUSTER_NAME" --principal-arn "arn:aws:iam::${ACCOUNT_ID}:user/rbac-user" 2>/dev/null || true
for key in $(aws iam list-access-keys --user-name rbac-user --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null); do
  aws iam delete-access-key --user-name rbac-user --access-key-id "$key"
done
aws iam delete-user --user-name rbac-user 2>/dev/null || true
rm -f rbacuser_creds.sh rbacuser-role.yaml rbacuser-role-binding.yaml /tmp/create_output.json
echo "RBAC cleaned up"

##> Clean up Storage (Topic 9: pods, claim, EBS volume, add-on, policy)
# Delete the PVC before the driver, so the driver can delete the EBS volume.
kubectl delete pod writer reader --ignore-not-found --wait=true
PV_NAME="$(kubectl get pvc data-pvc -o jsonpath='{.spec.volumeName}' 2>/dev/null)"
kubectl delete pvc data-pvc --ignore-not-found
[ -n "$PV_NAME" ] && kubectl wait --for=delete "pv/$PV_NAME" --timeout=120s
kubectl delete storageclass gp3 --ignore-not-found
if aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name aws-ebs-csi-driver >/dev/null 2>&1; then
  aws eks delete-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name aws-ebs-csi-driver --query addon.status --output text
  aws eks wait addon-deleted --cluster-name "$EKS_CLUSTER_NAME" --addon-name aws-ebs-csi-driver
fi
NODE_ROLE_ARN="$(aws eks describe-nodegroup --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name default --query nodegroup.nodeRole --output text 2>/dev/null)"
if [ -n "$NODE_ROLE_ARN" ] && [ "$NODE_ROLE_ARN" != "None" ]; then
  aws iam detach-role-policy --role-name "${NODE_ROLE_ARN##*/}" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy 2>/dev/null || true
fi
rm -rf "$DEMO_HOME/storage"
echo "Storage cleaned up"

##> Clean up CloudWatch (Topic 8: add-on, logging, node role policy)
# Topic 8's own cleanup step also deletes the CloudWatch log groups; this one keeps them.
if aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name amazon-cloudwatch-observability >/dev/null 2>&1; then
  aws eks delete-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name amazon-cloudwatch-observability
  aws eks wait addon-deleted --cluster-name "$EKS_CLUSTER_NAME" --addon-name amazon-cloudwatch-observability
fi
aws eks list-addons --cluster-name "$EKS_CLUSTER_NAME"
kubectl delete namespace amazon-cloudwatch --ignore-not-found
kubectl get pods -A | grep cloudwatch || echo "No CloudWatch pods left"
eksctl utils update-cluster-logging --cluster="$EKS_CLUSTER_NAME" --disable-types=all --approve
NODE_ROLE_ARN="$(aws eks describe-nodegroup --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name default --query nodegroup.nodeRole --output text 2>/dev/null)"
if [ -n "$NODE_ROLE_ARN" ] && [ "$NODE_ROLE_ARN" != "None" ]; then
  aws iam detach-role-policy --role-name "${NODE_ROLE_ARN##*/}" --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy 2>/dev/null || true
fi
echo "CloudWatch cleaned up"

##> Clean up MongoDB (Topic 7)
# Uses the copied manifests in ~/environment/mongo, so it only runs if Topic 7 was used.
if [ -d "$DEMO_HOME/mongo" ]; then
  kubectl delete -f "$DEMO_HOME/mongo/mongo-webapp.yaml" --ignore-not-found
  kubectl delete -f "$DEMO_HOME/mongo/mongo-configmap.yaml" --ignore-not-found
  kubectl delete -f "$DEMO_HOME/mongo/mongo-db.yaml" --ignore-not-found
  kubectl delete -f "$DEMO_HOME/mongo/mongo-secret.yaml" --ignore-not-found
fi

##> Clean up the monitoring components (Topic 6)
# The HPA demo and kube-ops-view (and its load balancer).
kubectl delete pod load-generator --ignore-not-found
kubectl delete hpa php-apache --ignore-not-found
kubectl delete service php-apache --ignore-not-found
kubectl delete deployment php-apache --ignore-not-found
helm uninstall kube-ops-view 2>/dev/null || true

##> Clean up Fluent Bit (in case Topic 5 was not finished)
helm uninstall aws-for-fluent-bit 2>/dev/null || true

##> Clean up the sample app from Topics 4 and 5 (app, load balancer, ECR repository)
# Covers both ways it was deployed: the Helm release (Topic 5) and kubectl apply (Topic 4).
# --force deletes the repository together with its images.
helm uninstall my-nginx-app 2>/dev/null || true
kubectl delete deployment,service my-nginx-app --ignore-not-found
aws ecr delete-repository --repository-name my-nginx-app --force --query repository.repositoryName --output text 2>/dev/null || echo "No ECR repository my-nginx-app"
echo "Sample app cleaned up"

##> Check that no load balancers are left
# Any LoadBalancer service listed here still has an AWS load balancer - delete it first.
kubectl get svc -A | grep LoadBalancer || echo "No LoadBalancer services left"
echo
echo "Remaining checks: verify resources in the AWS console, IAM roles/policies, and env variables."

##> (Optional) Delete the whole cluster - type DELETE to confirm
# eksctl deletes the node group, the cluster and the VPC (10-15 minutes).
read -r -p "Type DELETE to delete cluster ${EKS_CLUSTER_NAME} (anything else skips): " CONFIRM </dev/tty
if [ "$CONFIRM" = "DELETE" ]; then
  eksctl delete cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --wait
else
  echo "Cluster kept."
fi

##> (Optional) Schedule the KMS key for deletion - type DELETE to confirm
# KMS keys cannot be deleted at once: the key is disabled now and deleted after 7 days
# (cancel in the KMS console within that time). Topic 1 creates a new one next time.
read -r -p "Type DELETE to schedule alias/eksdemo key deletion in 7 days (anything else skips): " CONFIRM </dev/tty
if [ "$CONFIRM" = "DELETE" ]; then
  KEY_ID="$(aws kms describe-key --key-id alias/eksdemo --query KeyMetadata.KeyId --output text)"
  aws kms delete-alias --alias-name alias/eksdemo
  aws kms schedule-key-deletion --key-id "$KEY_ID" --pending-window-in-days 7
else
  echo "KMS key kept."
fi
