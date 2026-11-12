# EKS on AWS - class demos

## Run a demo in class
Open a terminal in Kiro (it is a bash shell on the class workstation) and type:

```bash
demo list        # show all topics
demo 1           # run Topic 1 one step at a time
```

For every step you see the commands first, then press:
- **Enter** to run it
- **s** to skip it
- **q** to stop (it tells you how to resume, for example `demo 3 2`)

Ctrl+C stops only the current command (useful for watch commands), not the whole topic.

Other forms:
- `demo 3 2` - start Topic 3 at step 2
- `demo show 6` - print Topic 6's steps without running them
- `demo 5 --yes` - run every step without pausing (rehearsals)

You can also open a topic file in `demos/`, select one step (from a `##>` line to the next)
and press Ctrl+Enter to run it in the terminal.

## Order of the topics
| Topic | File | What it does | Time |
|---|---|---|---|
| 0 | `topic-00-starter.sh` | Check AWS access, connect to the cluster, join tmux (`start`) | ~1 min |
| 1 | `topic-01-setup-tools.sh` | Check/update tools, workspace, KMS key | ~3 min |
| 2 | `topic-02-cluster-config.sh` | Write and validate `cluster.yaml` | ~1 min |
| 3 | `topic-03-create-cluster.sh` | Create the EKS cluster | **15-20 min** (run it inside tmux) |
| 4 | `topic-04-sample-app.sh` | Build the sample nginx image, push to ECR, deploy with kubectl | ~8 min |
| 5 | `topic-05-helm.sh` | Helm basics with Fluent Bit, then the sample app as a Helm chart | ~8 min |
| 6 | `topic-06-monitoring.sh` | kube-ops-view, metrics-server, HPA load test | ~10 min |
| 7 | `topic-07-networking.sh` | MongoDB + demo web app | ~5 min |
| 8 | `topic-08-observability.sh` | CloudWatch Observability add-on, Container Insights, control plane logs | ~6 min |
| 9 | `topic-09-storage.sh` | Storage: EBS CSI driver, PVC, write a file, read it from a new pod | ~5 min |
| 10 | `topic-10-rbac.sh` | RBAC with an IAM user and EKS access entries | ~3 min |
| 11 | `topic-11-cleanup.sh` | Cleanup (optionally delete the cluster and KMS key) | ~15 min with cluster |

Each topic file starts with a short description of what it does and the order of its steps.

## Cost reminder
While the cluster exists you pay for the EKS control plane, 3x m5.large nodes, a NAT gateway and
any load balancers (Topics 4-7). Run `demo 11` after class and delete the cluster.
