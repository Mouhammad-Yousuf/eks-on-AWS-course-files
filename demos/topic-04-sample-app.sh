#!/usr/bin/env bash
# Topic 4: Sample Application - build with Docker, push to ECR, deploy with kubectl
#
# Scenario: you have a small web site and want it running on EKS. You package it as a
# container image, store it in ECR, and deploy it with plain Kubernetes YAML.
#   PART A  Build the image and test it locally with Docker      (steps 1-6)
#   PART B  Create an ECR repository and push the image           (steps 7-9)
#   PART C  Deploy it with kubectl apply behind a load balancer   (steps 10-14)
#           A commented copy of the YAML: demos/my-nginx-app.yaml
# Cost: the load balancer is about $0.03/hour. Topic 11 deletes it and the ECR repository.

# =============================================================================
# PART A - Build a simple web app image and test it locally with Docker
# =============================================================================

##> Step 1: Create the project folder
# All files for this topic go in ~/environment/eksdemo
mkdir -p "$DEMO_HOME/eksdemo/html"
cd "$DEMO_HOME/eksdemo"
pwd

##> Step 2: Create the Dockerfile
# Start from the official nginx web server image and copy our web page into it
cd "$DEMO_HOME/eksdemo"
cat << 'EOF' > Dockerfile
FROM nginx:stable-alpine
COPY ./html/ /usr/share/nginx/html/
EXPOSE 80
EOF
cat Dockerfile

##> Step 3: Create the web page
# The page nginx will serve
cd "$DEMO_HOME/eksdemo"
cat << 'EOF' > html/index.html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Hello From EKS</title>
</head>
<body style="font-family: Arial, sans-serif; text-align: center; margin-top: 12%;">
  <h1>Hello Yousuf From EKS</h1>
  <p>Version: v1</p>
</body>
</html>
EOF
cat html/index.html

##> Step 4: Build the Docker image
# Build the image and tag it my-nginx-app:v1
cd "$DEMO_HOME/eksdemo"
docker build -t my-nginx-app:v1 .
docker images my-nginx-app

##> Step 5: Run the image locally and test it
# Start a container on port 8080 and fetch the page.
# Tip: to see it in your browser, open the PORTS tab in Kiro and open port 8080.
docker rm -f my-nginx-test >/dev/null 2>&1 || true
docker run -d --name my-nginx-test -p 127.0.0.1:8080:80 my-nginx-app:v1
sleep 2
docker ps --filter name=my-nginx-test
curl -s http://localhost:8080

##> Step 6: Stop the local test container
docker rm -f my-nginx-test
docker ps --filter name=my-nginx-test

# =============================================================================
# PART B - Create an ECR repository and push the image to it
# =============================================================================

##> Step 7: Create the ECR repository
# ECR is the AWS registry for container images. If the repository already exists, it is just shown.
aws ecr describe-repositories --repository-names my-nginx-app 2>/dev/null || aws ecr create-repository --repository-name my-nginx-app

##> Step 8: Log Docker in to ECR
# Gets a temporary password (valid 12 hours) and passes it straight to Docker - it is never shown
aws ecr get-login-password | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

##> Step 9: Tag the image with its ECR address and push it
# The tag tells Docker where the image goes: <account>.dkr.ecr.<region>.amazonaws.com/<repository>:<version>
export IMAGE="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/my-nginx-app:v1"
docker tag my-nginx-app:v1 "$IMAGE"
docker push "$IMAGE"
aws ecr list-images --repository-name my-nginx-app

# =============================================================================
# PART C - Deploy the image to EKS with kubectl apply (the manual way)
# =============================================================================

##> Step 10: Write the Kubernetes YAML
# Two objects in one file (both go in the default namespace):
#   Deployment - runs 2 copies (pods) of our image from ECR, and replaces them if they fail
#   Service    - type LoadBalancer: AWS creates a load balancer with a public address
# ${IMAGE} is replaced with your ECR image address when the file is written.
# A commented copy to show the students: demos/my-nginx-app.yaml
cd "$DEMO_HOME/eksdemo"
export IMAGE="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/my-nginx-app:v1"
cat << EOF > my-nginx-app.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-nginx-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: my-nginx-app
  template:
    metadata:
      labels:
        app: my-nginx-app
    spec:
      containers:
        - name: web
          image: ${IMAGE}
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
---
apiVersion: v1
kind: Service
metadata:
  name: my-nginx-app
spec:
  type: LoadBalancer
  selector:
    app: my-nginx-app
  ports:
    - port: 80
      targetPort: 80
EOF
cat my-nginx-app.yaml

##> Step 11: Deploy it with kubectl apply
# kubectl sends the YAML to the cluster. Running it again only applies what changed.
cd "$DEMO_HOME/eksdemo"
kubectl apply -f my-nginx-app.yaml

##> Step 12: Check the deployment, pods and service
# Waits until both pods are ready (up to 3 minutes), then lists what was created
kubectl rollout status deployment/my-nginx-app --timeout=180s
kubectl get deployment,pods,service -o wide

##> Step 13: Open the app through the load balancer
# The load balancer needs 1-3 minutes before it answers. If it does not answer yet, run this step again.
LB_HOST="$(kubectl get service my-nginx-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo "Load balancer: ${LB_HOST:-not created yet}"
curl -s -m 5 "http://$LB_HOST" | grep "Hello From EKS" || echo "No answer yet - wait a minute and run this step again."
echo "Open in your browser: http://$LB_HOST"

##> Step 14: (Optional) Remove the app from the cluster
# Deletes everything the YAML created (Deployment, Service and its load balancer).
# Skip this if you want to keep the app running - Topic 11 removes it anyway.
cd "$DEMO_HOME/eksdemo"
kubectl delete -f my-nginx-app.yaml --ignore-not-found