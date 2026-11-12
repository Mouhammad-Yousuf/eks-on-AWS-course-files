#!/usr/bin/env bash
# Topic 6: Monitoring and Metrics
#
# Scenario: traffic to an app goes up and down. You watch the cluster in kube-ops-view,
# read CPU and memory with metrics-server, and let the Horizontal Pod Autoscaler (HPA)
# add pods under load and remove them when the load stops.
#   kube-ops-view -> metrics -> php-apache app -> HPA -> generate load -> scale back -> delete

##> Install kube-ops-view
# A read-only web page that shows nodes and pods as boxes. LoadBalancer = public URL;
# rbac.create lets it read the cluster.
helm repo add christianhuth https://charts.christianhuth.de --force-update
helm repo update
helm upgrade --install kube-ops-view christianhuth/kube-ops-view \
  --set service.type=LoadBalancer \
  --set rbac.create=true
kubectl get svc kube-ops-view

##> Get the kube-ops-view URL (load balancer takes 2-3 minutes)
# Polls every 10s (up to 5 minutes) until AWS gives the load balancer a hostname.
for i in $(seq 1 30); do
  LB_HOST="$(kubectl get svc kube-ops-view -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
  [ -n "$LB_HOST" ] && break
  echo "waiting for load balancer... ($i)"; sleep 10
done
LB_PORT="$(kubectl get svc kube-ops-view -o jsonpath='{.spec.ports[0].port}')"
echo "kube-ops-view: http://${LB_HOST}:${LB_PORT}   (DNS can take a few more minutes)"

##> Check the metrics server (already installed as an EKS add-on)
# metrics-server collects CPU and memory from every node. kubectl top and the HPA read it
# through the metrics.k8s.io API. Available=True means that API answers.
aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name metrics-server --query '{status:addon.status,version:addon.addonVersion}' --output table
kubectl get deployment metrics-server -n kube-system
kubectl get apiservice v1beta1.metrics.k8s.io

##> Check node and pod metrics
# The first numbers can take a few seconds after the metrics server starts.
sleep 20
kubectl top nodes
kubectl top pods -A | head -n 10

##> Deploy the sample app for metrics testing
# php-apache does CPU work on every request. The 200m CPU request is the 100% mark
# that the HPA percentage is measured against.
kubectl create deployment php-apache --image=registry.k8s.io/hpa-example --dry-run=client -o yaml | kubectl apply -f -
kubectl set resources deploy php-apache --requests=cpu=200m
kubectl get svc php-apache >/dev/null 2>&1 || kubectl expose deploy php-apache --port 80
kubectl rollout status deploy/php-apache --timeout=180s
kubectl get pod -l app=php-apache

##> Configure the Horizontal Pod Autoscaler
# Keep average CPU near 50% of the request, with 1 to 10 pods.
kubectl get hpa php-apache >/dev/null 2>&1 || kubectl autoscale deployment php-apache \
    --cpu-percent=50 \
    --min=1 \
    --max=10
kubectl get hpa

##> Connect to busybox and generate load
# At the busybox prompt (/ #) type:
#   while true; do wget -q -O - http://php-apache; done
# It prints OK! for every request. The HPA scales out in 1-2 min
# (watch it in kube-ops-view, or run "kubectl get hpa -w" in a second terminal).
# To stop the load: press Ctrl+C, then type "exit" to return to your terminal.
kubectl run -it --rm load-generator --image=busybox:1.36 --restart=Never -- /bin/sh

##> Check the HPA after the load stops
# Replicas go back to 1 about 5 min after the load stops.
kubectl get hpa php-apache
kubectl get pods -l app=php-apache

##> Delete the HPA demo
# kube-ops-view stays for later topics; Topic 11 removes it.
kubectl delete pod load-generator --ignore-not-found
kubectl delete hpa php-apache --ignore-not-found
kubectl delete service php-apache --ignore-not-found
kubectl delete deployment php-apache --ignore-not-found
