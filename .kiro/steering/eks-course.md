# EKS on AWS course - instructor workstation

## What this workspace is
The instructor's class workstation for delivering the "EKS on AWS" course. Kiro runs here
(Remote-SSH) so it can read the course material and run the demo commands directly.

- `original/` - the instructor's original Module 1-9 Word documents (`*.docx`) and a plain-text
  copy of each (`original/text/`). Treat these as read-only reference.
- `demos/topic-NN-<name>.sh` - the tested demo scripts the instructor runs in class (Topic 0-11).
- `demos/manifests/` - Kubernetes manifests used by the demos (MongoDB for Topic 7).
- `demos/lib/demo.sh` - the step runner (`demo 3`, `demo 3 2`, `demo 3 --yes`, `demo show 3`).
- `demos/lib/env.sh` - shared settings, sourced by every shell.

## Environment
- Amazon Linux 2023, user `ec2-user`, region `us-west-2`, cluster name `eksdev`.
- Workspace for demo output: `~/environment` (`$DEMO_HOME`). Do not write demo output into `~/eks-course`.
  `~/eks-course/environment` is a symlink to `~/environment` so the instructor sees demo output
  (eksdemo/, my-nginx-chart/, cluster.yaml) in Kiro's left panel.
- The instance role has administrator permissions. Commands here can create real, billable
  AWS resources (EKS ~$0.10/h per cluster, 3x m5.large nodes, NAT gateway, load balancers).
- Tools pre-installed: aws (v2), kubectl, eksctl, helm, docker (+buildx), jq, yq, git, tmux.

## Demo script conventions (follow these when editing or adding demos)
- Each step begins with a line `##> Step title`. Everything until the next `##> ` is that step.
- Steps run in the instructor's interactive shell (via `eval`), so:
  - never use `exit`; never use `set -e`; `return` would stop the whole topic.
  - exports and `cd` carry over to the next step.
- Every step must be safe to re-run: `--dry-run=client -o yaml | kubectl apply -f -`,
  `helm upgrade --install`, "create only if missing", `--ignore-not-found` on deletes.
- Anything that never ends on its own (`--watch`, `logs -f`) is wrapped in `watch_for SECONDS ...`.
- No `\` line continuations in the middle of pasted commands unless inside a single command.
- Never print secrets (access keys, passwords) to the screen - the instructor is projecting.
- Plain ASCII only: no smart quotes or en-dashes (an en-dash in "--update" breaks the command).
- Prefer looking values up (account ID, node role name, versions) over hardcoding them.
- Each topic file starts with a short header: what it does, the flow of its steps, and Notes.
  Each step has a short comment above its commands explaining what they do.
- The demos, manifests and README are shared with students: never mention the original
  documents, earlier script versions, or what changed. Say "Topic N", never "Module N".

## Working agreement (instructor's preference)
- Kiro WRITES and explains the demo steps. The instructor runs them (select + Ctrl+Enter, or `demo N`)
  and asks for help when something fails. Kiro then reads the `class` tmux screen and fixes the script.
- Do not run demo steps, test-run topics, or create AWS resources unless the instructor asks.
  Read-only checks (syntax, `demo show N`, reading files) are fine.

## Rehearsing a topic with the instructor
If `demo` or `$EKS_CLUSTER_NAME` is not defined in your shell, load them first:
`source ~/eks-course/demos/lib/env.sh && source ~/eks-course/demos/lib/demo.sh`

1. Read the topic's source text in `original/text/` (instructor-only) and the script.
2. Run it step by step with `demo N --yes` (or one step at a time) and watch the output.
3. If a step fails: find the root cause, fix the script, re-run from that step (`demo N <step>`).
4. Keep the header and step comments accurate (no change history).
Topics depend on each other in order: 1 tools -> 2 cluster.yaml -> 3 create cluster (15-20 min)
-> 4 Docker image -> 5 Helm -> 6 monitoring -> 7 MongoDB -> 8 CloudWatch observability -> 9 storage
-> 10 RBAC -> 11 cleanup.

## Cost and safety
- Remind the instructor to run `demo 11` (cleanup) and delete the cluster after class.
- Ask before deleting the cluster, IAM users/roles, or KMS keys outside Topic 11.
