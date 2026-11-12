#!/usr/bin/env bash
# Topic 8: CloudWatch Observability on EKS
#
# Scenario: the cluster is running and you need to see what happens inside it. One EKS
# add-on sends node and pod metrics (Container Insights) and container logs to CloudWatch.
#   node role permission -> add-on -> what it installed -> log-demo pod -> logs -> metrics
#   -> (optional) control plane logs -> clean up
# Cost: CloudWatch metrics and logs are billed. Run the last step after class.

##> Find the node group IAM role
# Every EC2 worker node runs with this role. Pods that use the node's credentials get its permissions.
NODE_ROLE_ARN="$(aws eks describe-nodegroup --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name default --query nodegroup.nodeRole --output text)"
export ROLE_NAME="${NODE_ROLE_ARN##*/}"
echo "ROLE_NAME=${ROLE_NAME}"

##> Allow the nodes to send metrics and logs to CloudWatch
# CloudWatchAgentServerPolicy = write metrics, logs and traces. Safe to re-run.
# (Production: AWS recommends EKS Pod Identity, so not every pod on the node gets this.)
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query 'AttachedPolicies[].PolicyName' --output table

##> Install the CloudWatch Observability add-on (3-5 minutes)
# Not installed by default: EKS only adds vpc-cni, coredns, kube-proxy (and metrics-server).
# This one add-on deploys 3 things:
#   - cloudwatch-agent DaemonSet: one pod per node, sends node/pod metrics (Container Insights)
#   - fluent-bit DaemonSet: one pod per node, sends container logs to CloudWatch Logs
#   - controller-manager (the "operator"): a pod that creates and repairs the cloudwatch-agent
#     DaemonSet from its settings object (kind AmazonCloudWatchAgent)
if aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name amazon-cloudwatch-observability >/dev/null 2>&1; then
  echo "Add-on already installed"
else
  aws eks create-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name amazon-cloudwatch-observability --query addon.status --output text
fi
aws eks wait addon-active --cluster-name "$EKS_CLUSTER_NAME" --addon-name amazon-cloudwatch-observability
aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name amazon-cloudwatch-observability --query '{status:addon.status,version:addon.addonVersion}' --output table

##> See what the add-on installed
# 2 DaemonSets do the work (cloudwatch-agent = metrics, fluent-bit = logs, one pod per node)
# and 1 Deployment manages them (controller-manager = the operator).
# The other DaemonSets show 0 pods on purpose: *-windows (Windows nodes), dcgm-exporter (NVIDIA
# GPU nodes) and neuron-monitor (AWS Inferentia/Trainium nodes). We have none of those nodes.
kubectl get daemonset,deployment -n amazon-cloudwatch
# The pods they created. -o wide adds the NODE column: one agent + one fluent-bit pod per node.
kubectl get pods -n amazon-cloudwatch -o wide
# The operator's settings object. The operator builds the cloudwatch-agent DaemonSet from it.
kubectl get amazoncloudwatchagents -n amazon-cloudwatch

##> (Optional) Enable control plane logging (API server and audit logs)
# AWS runs the EKS control plane. These logs are the only way to see what it did.
# This step runs nothing. Pick one way to turn the logs on (takes 1-2 minutes):
#   Console: EKS > Clusters > eksdev > Observability tab > Control plane logs >
#            Manage logging > turn on "API server" and "Audit" > Save changes
#   CLI:     select the command below (without the #) and press Ctrl+Enter
#            (--approve is required, otherwise eksctl only prints the plan)
#   eksctl utils update-cluster-logging --cluster="$EKS_CLUSTER_NAME" --enable-types=api,audit --approve
echo "Optional: enable API server + Audit logs in the EKS console (Observability tab)"

##> Start a pod that writes logs (log-demo)
# Prints one line every 5 seconds. Fluent Bit picks it up and sends it to CloudWatch Logs.
kubectl run log-demo --image=busybox:1.36 --restart=Never --dry-run=client -o yaml -- sh -c 'i=0; while true; do i=$((i+1)); echo "log-demo: hello from EKS, line $i"; sleep 5; done' | kubectl apply -f -
kubectl wait --for=condition=Ready pod/log-demo --timeout=120s
# The same lines, read from the pod directly (what kubectl logs shows):
kubectl logs log-demo --tail=3

##> Find the log-demo lines in CloudWatch Logs (can take 1-3 minutes)
# Container logs go to the log group /aws/containerinsights/<cluster>/application.
APP_LOG_GROUP="/aws/containerinsights/${EKS_CLUSTER_NAME}/application"
for i in $(seq 1 18); do
  # Each event is JSON (the line + pod/node details). sed keeps only the time and the "log" text.
  CW_LINES="$(aws logs tail "$APP_LOG_GROUP" --since 10m --filter-pattern '"log-demo"' --format short 2>/dev/null | tail -n 5 | sed -E 's/^([^ ]+) .*"log":"([^"]*)".*/\1  \2/')"
  [ -n "$CW_LINES" ] && break
  echo "waiting for logs to reach CloudWatch... ($i)"; sleep 10
done
echo "${CW_LINES:-No lines yet - try this step again in a minute}"
echo "Console: CloudWatch > Logs > Log groups > ${APP_LOG_GROUP}"

##> See Container Insights metrics (CPU, memory, network per node and pod)
# The CloudWatch agent sends metrics to the "ContainerInsights" namespace, per cluster.
# The first metrics arrive 1-3 minutes after the add-on starts, so wait until there are some.
for i in $(seq 1 18); do
  [ "$(aws cloudwatch list-metrics --namespace ContainerInsights --dimensions Name=ClusterName,Value="$EKS_CLUSTER_NAME" --query 'length(Metrics)')" != "0" ] && break
  echo "waiting for the first metrics... ($i)"; sleep 10
done
# Print the node and pod CPU / memory / network metric names (the ones the console graphs use):
aws cloudwatch list-metrics --namespace ContainerInsights --dimensions Name=ClusterName,Value="$EKS_CLUSTER_NAME" --query 'Metrics[].MetricName' --output text | tr '\t' '\n' | sort -u | grep -E '^(node|pod)_(cpu|memory|network)' | head -n 15
echo "Console: CloudWatch > Insights > Container Insights (pick cluster ${EKS_CLUSTER_NAME})"

##> (Optional) See the control plane logs (only if you enabled them in the previous optional step)
# Each line is one request to the Kubernetes API (who did what). Cut to 200 characters for the screen.
# If logging is not enabled this waits 3 minutes and prints "No lines yet" - skip it with s.
CP_LOG_GROUP="/aws/eks/${EKS_CLUSTER_NAME}/cluster"
for i in $(seq 1 18); do
  CP_LINES="$(aws logs tail "$CP_LOG_GROUP" --since 10m --format short 2>/dev/null | tail -n 5 | cut -c1-200)"
  [ -n "$CP_LINES" ] && break
  echo "waiting for control plane logs... ($i)"; sleep 10
done
echo "${CP_LINES:-No lines yet - try this step again in a minute}"
echo "Console: CloudWatch > Logs > Log groups > ${CP_LOG_GROUP}"

##> Clean up Topic 8 (add-on, logging, policy, log groups)
# Order matters: remove the add-on first, so Fluent Bit stops writing before the log groups are deleted.
kubectl delete pod log-demo --ignore-not-found
if aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name amazon-cloudwatch-observability >/dev/null 2>&1; then
  aws eks delete-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name amazon-cloudwatch-observability --query addon.status --output text
  aws eks wait addon-deleted --cluster-name "$EKS_CLUSTER_NAME" --addon-name amazon-cloudwatch-observability
fi
kubectl delete namespace amazon-cloudwatch --ignore-not-found
eksctl utils update-cluster-logging --cluster="$EKS_CLUSTER_NAME" --disable-types=all --approve
NODE_ROLE_ARN="$(aws eks describe-nodegroup --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name default --query nodegroup.nodeRole --output text)"
aws iam detach-role-policy --role-name "${NODE_ROLE_ARN##*/}" --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy 2>/dev/null || echo "Policy already detached"
for g in $(aws logs describe-log-groups --log-group-name-prefix "/aws/containerinsights/${EKS_CLUSTER_NAME}/" --query 'logGroups[].logGroupName' --output text) "/aws/eks/${EKS_CLUSTER_NAME}/cluster"; do
  aws logs delete-log-group --log-group-name "$g" 2>/dev/null && echo "Deleted log group $g"
done
echo "Topic 8 cleaned up"
