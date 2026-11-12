# shellcheck shell=bash
# Shared settings for every demo topic. Sourced from ~/.bashrc on the workstation.
export AWS_PAGER=""
export AWS_REGION="${AWS_REGION:-us-west-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-eksdev}"
export DEMO_HOME="${DEMO_HOME:-$HOME/environment}"

# Account ID is looked up once and cached, so new terminals open quickly.
_acct_cache="$HOME/.cache/eks-course-account-id"
if [[ -z "${ACCOUNT_ID:-}" ]]; then
  if [[ -s "$_acct_cache" ]]; then
    ACCOUNT_ID="$(cat "$_acct_cache")"
  else
    ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
    [[ -n "$ACCOUNT_ID" ]] && mkdir -p "${_acct_cache%/*}" && echo "$ACCOUNT_ID" > "$_acct_cache"
  fi
  export ACCOUNT_ID
fi
unset _acct_cache
