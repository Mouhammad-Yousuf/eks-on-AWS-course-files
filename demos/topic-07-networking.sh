#!/usr/bin/env bash
# Topic 7: MongoDB Deployment
#
# Scenario: a web app that stores user profiles in a database. MongoDB runs inside the
# cluster (internal only). The web app is public and gets the database address from a
# ConfigMap and the login from a Secret.
#   Secret + ConfigMap -> MongoDB -> web app -> open in browser -> read the data -> clean up

##> Copy the manifests into the workspace
mkdir -p "$DEMO_HOME/mongo"
cp ~/eks-course/demos/manifests/mongo-*.yaml "$DEMO_HOME/mongo/"
cd "$DEMO_HOME/mongo"
ls -l

##> Look at the Secret and ConfigMap
# Secret = the database user and password (base64, not encrypted in the file).
# ConfigMap = non-secret settings: where the database is (mongodb-service).
cat mongo-secret.yaml
cat mongo-configmap.yaml

##> Apply the MongoDB configurations and the web app
# The Secret goes first: the MongoDB pod reads its root login from it at start.
kubectl apply -f mongo-secret.yaml
kubectl apply -f mongo-db.yaml
kubectl apply -f mongo-configmap.yaml
kubectl apply -f mongo-webapp.yaml

##> Verify the MongoDB deployment
# Watch the pods start (stops after 60s), then list what was created.
kubectl get pod
watch_for 60 kubectl get pod --watch
kubectl get pod -o wide
kubectl get service
kubectl get secret
kubectl get all | grep mongodb

##> Debug the deployment
# describe shows events (image pull, scheduling, errors); the logs show the app connecting.
kubectl describe pod mongodb
kubectl describe service mongodb-service
kubectl get all | grep webapp
watch_for 30 kubectl logs deploy/webapp -f

##> Open the web app in the browser
# Click "Edit Profile", change the fields, click "Update Profile". The change is saved in MongoDB.
for i in $(seq 1 30); do
  APP_HOST="$(kubectl get svc webapp-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
  [ -n "$APP_HOST" ] && break
  echo "waiting for load balancer... ($i)"; sleep 10
done
echo "Web app: http://${APP_HOST}   (DNS can take a few more minutes)"

##> See the saved profile in MongoDB
# Runs mongosh inside the MongoDB pod. The password comes from the pod's env, not the screen.
kubectl exec deploy/mongodb -- sh -c 'mongosh --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin my-db --eval "db.users.find().toArray()"'

##> Clean up Topic 7
# Removes the web app, its load balancer, MongoDB, the Secret and ConfigMap (the data goes too).
cd "$DEMO_HOME/mongo"
kubectl delete -f mongo-webapp.yaml --ignore-not-found
kubectl delete -f mongo-configmap.yaml --ignore-not-found
kubectl delete -f mongo-db.yaml --ignore-not-found
kubectl delete -f mongo-secret.yaml --ignore-not-found
kubectl get all | grep -E "mongo|webapp" || echo "Topic 7 cleaned up"
