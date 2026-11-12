#!/usr/bin/env bash
# Topic 5: Helm Setup and Package Management
#
# Scenario: deploying with raw YAML gets repetitive. Helm packages a Kubernetes app as a
# chart that you install, upgrade and roll back with one command each.
#   PART A  Helm basics with a public chart (Fluent Bit): install, upgrade, history, rollback
#   PART B  Package the Topic 4 web app as your own chart (needs the image from Topic 4)

# =============================================================================
# PART A - Helm basics with a public chart (Fluent Bit)
# =============================================================================

##> Install Helm (skips if already installed)
# Helm is the package manager for Kubernetes: a "chart" is a package, a "release" is
# one installed copy of a chart.
if command -v helm >/dev/null 2>&1; then
  echo "Helm already installed"
else
  curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod 700 /tmp/get_helm.sh
  /tmp/get_helm.sh
fi
helm version

##> Configure Helm repositories
# A repository is a web site that lists charts. "eks" is AWS's chart repository.
helm repo list || echo "(no repositories yet)"
helm repo add eks https://aws.github.io/eks-charts --force-update
helm repo update
helm repo list

##> Search for the Fluent Bit chart
helm search repo fluent

##> Install Fluent Bit
# Release name aws-for-fluent-bit. --set overrides one value of the chart.
helm upgrade --install aws-for-fluent-bit eks/aws-for-fluent-bit --set cloudWatchLogs.region="$AWS_REGION"

##> Verify the installation
# Fluent Bit is a DaemonSet: one pod on every node
helm list
kubectl get daemonset,pods

##> Upgrade, view history, and test a rollback (dry run)
# Every upgrade is a new revision. --reuse-values keeps the settings from the install.
# --dry-run shows what the rollback would do without changing anything.
helm upgrade aws-for-fluent-bit eks/aws-for-fluent-bit --reuse-values
helm history aws-for-fluent-bit
helm rollback aws-for-fluent-bit 1 --dry-run

##> Uninstall Fluent Bit
# Removes everything the release created.
helm uninstall aws-for-fluent-bit

# =============================================================================
# PART B - Package the Topic 4 app as our own Helm chart
# =============================================================================
# Topic 4 deployed my-nginx-app with kubectl apply. Now we deploy the same app with Helm.
# A chart is a folder:  Chart.yaml (name + version), values.yaml (settings),
# templates/ (the Topic 4 YAML, with the settings replaced by {{ .Values... }}).

##> Remove the kubectl version of the app (from Topic 4)
# Helm cannot take over objects that kubectl created, so remove them first.
kubectl delete -f "$DEMO_HOME/eksdemo/my-nginx-app.yaml" --ignore-not-found

##> Create the chart folder and Chart.yaml
# (helm create my-nginx-chart makes the same layout, with many extra example files)
mkdir -p "$DEMO_HOME/my-nginx-chart/templates"
cd "$DEMO_HOME/my-nginx-chart"
cat << 'EOF' > Chart.yaml
apiVersion: v2
name: my-nginx-chart
description: The Topic 4 web app, packaged as a Helm chart
version: 0.1.0
appVersion: "v1"
EOF
cat Chart.yaml

##> Write values.yaml (the settings you can change at install time)
# The ECR image address is filled in now (unquoted EOF), the rest are plain defaults.
cd "$DEMO_HOME/my-nginx-chart"
cat << EOF > values.yaml
image: ${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/my-nginx-app:v1
replicas: 2
service:
  type: LoadBalancer
  port: 80
EOF
cat values.yaml

##> Write the Deployment template (Topic 4 Deployment, settings come from values.yaml)
# Same YAML as Topic 4, but name, replicas and image are now {{ ... }}.
# .Release.Name is the name given to "helm install" (my-nginx-app).
cd "$DEMO_HOME/my-nginx-chart"
cat << 'EOF' > templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicas }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
    spec:
      containers:
        - name: web
          image: {{ .Values.image }}
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              memory: 64Mi
EOF
cat templates/deployment.yaml

##> Write the Service template (Topic 4 Service, settings come from values.yaml)
cd "$DEMO_HOME/my-nginx-chart"
cat << 'EOF' > templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
spec:
  type: {{ .Values.service.type }}
  selector:
    app: {{ .Release.Name }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: 80
EOF
cat templates/service.yaml

##> Check the chart and preview the YAML Helm will send
# helm lint checks the chart; helm template fills in the values and prints the result
# (compare it with Topic 4's YAML). Nothing is sent to the cluster.
cd "$DEMO_HOME"
helm lint ./my-nginx-chart
helm template my-nginx-app ./my-nginx-chart

##> Install the chart
# Release name my-nginx-app
cd "$DEMO_HOME"
helm upgrade --install my-nginx-app ./my-nginx-chart
helm list
kubectl rollout status deployment/my-nginx-app --timeout=180s
kubectl get deployment,pods,service

##> Open the app through the load balancer
# A new load balancer: it needs 1-3 minutes. If it does not answer yet, run this step again.
LB_HOST="$(kubectl get service my-nginx-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo "Load balancer: ${LB_HOST:-not created yet}"
curl -s -m 5 "http://$LB_HOST" | grep "Hello From EKS" || echo "No answer yet - wait a minute and run this step again."
echo "Open in your browser: http://$LB_HOST"

##> Upgrade: change a value without editing any YAML (3 replicas)
# --set replicas=3 overrides values.yaml for this revision only.
cd "$DEMO_HOME"
helm upgrade my-nginx-app ./my-nginx-chart --set replicas=3
kubectl rollout status deployment/my-nginx-app --timeout=180s
kubectl get pods

##> History and rollback to revision 1 (back to 2 replicas)
# A rollback is itself a new revision (a copy of revision 1).
helm history my-nginx-app
helm rollback my-nginx-app 1
kubectl get pods
helm history my-nginx-app

##> (Optional) Uninstall the app - one command removes everything, load balancer included
helm uninstall my-nginx-app
kubectl get deployment,service
