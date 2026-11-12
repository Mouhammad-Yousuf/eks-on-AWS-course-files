#!/usr/bin/env bash
# Topic 0: Starter - run this every time you come back to the workstation
#
# Run this every time you come back to the workstation (short command: start).
# It checks AWS access, connects kubectl to the cluster if one exists, sets up the
# Ctrl+Enter shortcut and joins the shared terminal session "class".

##> Check the workstation and AWS access
# Shows the settings from lib/env.sh and confirms the instance role works.
echo "Host:    $(hostname)  (user: $(whoami))"
echo "Region:  $AWS_REGION   Cluster name: $EKS_CLUSTER_NAME   Demo output: $DEMO_HOME"
mkdir -p "$DEMO_HOME"
if aws sts get-caller-identity >/dev/null 2>&1; then
  echo "AWS:     credentials OK"
else
  echo "AWS:     NOT working - check the instance role"
fi

##> Check the cluster and connect kubectl to it
# ACTIVE: write the kubeconfig and list the nodes. NONE: no cluster yet, start at Topic 1.
CLUSTER_STATUS="$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --query cluster.status --output text 2>/dev/null || echo NONE)"
echo "Cluster $EKS_CLUSTER_NAME: $CLUSTER_STATUS"
if [[ "$CLUSTER_STATUS" == "ACTIVE" ]]; then
  aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" >/dev/null && echo "kubectl now points at $EKS_CLUSTER_NAME"
  kubectl get nodes
  echo "Reminder: the cluster is billing while it runs. Run 'demo 11' after class."
elif [[ "$CLUSTER_STATUS" == "NONE" ]]; then
  echo "No cluster yet. Next: demo 1 (tools) -> demo 2 -> demo 3 (creates the cluster)."
else
  echo "Cluster is $CLUSTER_STATUS - check again in a few minutes."
fi

##> Make sure Ctrl+Enter runs selected script lines in the terminal
# Installs the small keybinding extension (tools/eks-run-selection.vsix) if it is missing,
# for example on a freshly built server.
RUNSEL_VSIX="$HOME/eks-course/tools/eks-run-selection.vsix"
if grep -q '"eks-course.run-selection"' "$HOME/.kiro-server/extensions/extensions.json" 2>/dev/null; then
  echo "Ctrl+Enter shortcut: installed (select lines in a .sh file, press Ctrl+Enter)"
else
  KIRO_CLI="$(command -v kiro || ls "$HOME"/.kiro-server/bin/*/bin/remote-cli/kiro 2>/dev/null | head -n 1)"
  if [[ -n "$KIRO_CLI" && -f "$RUNSEL_VSIX" ]] && "$KIRO_CLI" --install-extension "$RUNSEL_VSIX" >/dev/null 2>&1; then
    echo "Ctrl+Enter shortcut: installed now - reload the window once (Ctrl+Shift+P > Developer: Reload Window)"
  else
    echo "Ctrl+Enter shortcut: not installed - run 'start' in a new Kiro terminal (outside tmux)"
  fi
fi

##> Open the shared terminal session (Kiro can read it)
# Creates or re-joins tmux session "class". Long commands survive a dropped connection.
if [[ -n "${TMUX:-}" ]]; then
  echo "Already inside tmux session: $(tmux display-message -p '#S')"
else
  echo "Joining tmux session 'class'. Detach with Ctrl+b then d."
  env -u PROMPT_COMMAND tmux new-session -A -s class -c "$HOME/eks-course"
fi
