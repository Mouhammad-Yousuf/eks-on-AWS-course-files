#!/usr/bin/env bash
# Topic 9: Storage
#
# Scenario: a container's own disk disappears with its pod. You give the pod an EBS volume
# through a PersistentVolumeClaim, write a file, delete the pod, and read the file from a
# new pod.
#   driver + IAM -> StorageClass -> PVC (Pending) -> pod (EBS volume + PV created, mounted)
#   -> write a file -> delete the pod -> new pod, same PVC -> read the file -> clean up
# Cost: one 1 GiB gp3 volume (~$0.08/month). The last step deletes everything.

##> Find the node IAM role
# The EBS CSI driver runs as pods on the worker nodes and uses the node's IAM role.
# Look up that role from the "default" node group and keep only its name.
NODE_ROLE_ARN="$(aws eks describe-nodegroup --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name default --query nodegroup.nodeRole --output text)"
export ROLE_NAME="${NODE_ROLE_ARN##*/}"
echo "ROLE_NAME=${ROLE_NAME}"
##> Give the node role permission to manage EBS volumes
# AmazonEBSCSIDriverPolicy allows CreateVolume, AttachVolume, DeleteVolume and similar calls.
# (Production: AWS recommends EKS Pod Identity instead of the node role.)
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
# List the role's policies to confirm it is attached.
aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query 'AttachedPolicies[].PolicyName' --output table
##> Install the EBS CSI driver add-on (1-2 minutes)
# EKS has no storage driver by default. This add-on turns a Kubernetes volume request into an EBS volume.
# Create it only if it is not installed yet.
aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name aws-ebs-csi-driver >/dev/null 2>&1 || aws eks create-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name aws-ebs-csi-driver --query addon.status --output text
# Wait until the add-on is ACTIVE.
aws eks wait addon-active --cluster-name "$EKS_CLUSTER_NAME" --addon-name aws-ebs-csi-driver && echo "aws-ebs-csi-driver is ACTIVE"
##> See the driver pods
# ebs-csi-controller: creates, attaches and deletes EBS volumes (talks to the EC2 API).
# ebs-csi-node: one per node, mounts the attached volume into the pod.
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver -o wide
##> Create the StorageClass (what kind of disk)
mkdir -p "$DEMO_HOME/storage" && cd "$DEMO_HOME/storage"
# provisioner ebs.csi.aws.com: the EBS CSI driver creates the disks.
# type gp3, encrypted: the kind of EBS volume to create.
# WaitForFirstConsumer: create the disk only when a pod uses it, in that pod's availability zone
#   (an EBS volume lives in ONE AZ and can only attach to a node in that AZ).
# reclaimPolicy Delete: deleting the PVC also deletes the EBS volume.
cat << 'EOF' > storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
EOF
kubectl apply -f storageclass.yaml
# List all StorageClasses: gp2 came with the cluster, gp3 is ours.
kubectl get storageclass
##> Create the PersistentVolumeClaim (I need 1 GiB of that kind)
# The PVC is the request. ReadWriteOnce = can be mounted by one node at a time (true for EBS).
cat << 'EOF' > pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-pvc
spec:
  storageClassName: gp3
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF
kubectl apply -f pvc.yaml
# STATUS is Pending on purpose: no pod uses it yet, so no EBS volume exists yet.
kubectl get pvc data-pvc
# No PersistentVolume exists yet either.
kubectl get pv
##> Create the writer pod with the PVC in its spec
# volumes: use the claim data-pvc.  volumeMounts: show it inside the container at /data.
# The container only sleeps, so we can run commands in it.
cat << 'EOF' > writer-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: writer
spec:
  containers:
    - name: app
      image: public.ecr.aws/docker/library/busybox:stable
      command: ["sleep", "3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: data-pvc
EOF
kubectl apply -f writer-pod.yaml
# Wait (~30 s): EBS creates the volume, attaches it to the pod's node, the node mounts it.
kubectl wait --for=condition=Ready pod/writer --timeout=180s
# -o wide shows which node the pod runs on.
kubectl get pod writer -o wide
##> See what Kubernetes created: PVC Bound, PV created
# The PVC is now Bound to a PersistentVolume.
kubectl get pvc data-pvc
# The PV was created automatically by the driver (we never wrote a PV).
kubectl get pv
##> See the real EBS volume in AWS
# The PV stores the EBS volume ID in spec.csi.volumeHandle.
PV_NAME="$(kubectl get pvc data-pvc -o jsonpath='{.spec.volumeName}')"
export VOLUME_ID="$(kubectl get pv "$PV_NAME" -o jsonpath='{.spec.csi.volumeHandle}')"
echo "PV ${PV_NAME} = EBS volume ${VOLUME_ID}"
# Ask EC2 about it: gp3, 1 GiB, encrypted, in-use, attached to the writer pod's node.
aws ec2 describe-volumes --volume-ids "$VOLUME_ID" --query 'Volumes[0].{Volume:VolumeId,Type:VolumeType,SizeGiB:Size,AZ:AvailabilityZone,Encrypted:Encrypted,State:State,AttachedTo:Attachments[0].InstanceId}' --output table
echo "Console: EC2 > Elastic Block Store > Volumes > ${VOLUME_ID}"
##> Write a file to the volume
# Run a shell inside the writer pod and write one line into /data/hello.txt.
kubectl exec writer -- sh -c 'echo "Written by pod $(hostname) at $(date)" > /data/hello.txt'
# Read it back from the same pod.
kubectl exec writer -- cat /data/hello.txt
# df: /data is a separate ~1 GiB disk (the EBS volume), not the container's own filesystem.
kubectl exec writer -- df -h /data
##> Delete the writer pod
# The pod and its container are gone, but the PVC, the PV and the EBS volume stay.
kubectl delete pod writer --ignore-not-found --wait=true
# The PVC is still Bound.
kubectl get pvc data-pvc
# Wait until the EBS volume is detached ("available"). It still holds the file.
export VOLUME_ID="$(kubectl get pv "$(kubectl get pvc data-pvc -o jsonpath='{.spec.volumeName}')" -o jsonpath='{.spec.csi.volumeHandle}')"
aws ec2 wait volume-available --volume-ids "$VOLUME_ID"
aws ec2 describe-volumes --volume-ids "$VOLUME_ID" --query 'Volumes[0].{Volume:VolumeId,State:State}' --output table
##> Create a new reader pod with the same PVC
# Same claim, different pod. The scheduler puts it in the volume's AZ automatically.
cat << 'EOF' > reader-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: reader
spec:
  containers:
    - name: app
      image: public.ecr.aws/docker/library/busybox:stable
      command: ["sleep", "3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: data-pvc
EOF
kubectl apply -f reader-pod.yaml
# Wait until the volume is attached to the reader's node and mounted.
kubectl wait --for=condition=Ready pod/reader --timeout=180s
kubectl get pod reader -o wide
##> Read the file from the new pod
# It still says "Written by pod writer": the data lives on the EBS volume, not in the pod.
kubectl exec reader -- cat /data/hello.txt
##> Clean up Topic 9 (pods, PVC, EBS volume, StorageClass, add-on, policy)
cd "$DEMO_HOME"
# Delete the pods first, so the volume is detached.
kubectl delete pod writer reader --ignore-not-found --wait=true
# Delete the PVC while the driver is still installed: reclaimPolicy Delete removes the PV and the EBS volume.
PV_NAME="$(kubectl get pvc data-pvc -o jsonpath='{.spec.volumeName}' 2>/dev/null)"
kubectl delete pvc data-pvc --ignore-not-found
[ -n "$PV_NAME" ] && kubectl wait --for=delete "pv/$PV_NAME" --timeout=120s
# Delete the StorageClass.
kubectl delete storageclass gp3 --ignore-not-found
# Remove the add-on and wait until it is gone.
if aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name aws-ebs-csi-driver >/dev/null 2>&1; then
  aws eks delete-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name aws-ebs-csi-driver --query addon.status --output text
  aws eks wait addon-deleted --cluster-name "$EKS_CLUSTER_NAME" --addon-name aws-ebs-csi-driver
fi
# Remove the EBS permission from the node role.
NODE_ROLE_ARN="$(aws eks describe-nodegroup --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name default --query nodegroup.nodeRole --output text)"
aws iam detach-role-policy --role-name "${NODE_ROLE_ARN##*/}" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy 2>/dev/null || echo "Policy already detached"
# Remove the YAML files written by this topic.
rm -rf "$DEMO_HOME/storage"
echo "Topic 9 cleaned up"
