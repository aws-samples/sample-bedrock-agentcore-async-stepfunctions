#!/usr/bin/env bash
#
# destroy.sh — removes EVERYTHING that deploy.sh created:
#   1. detaches the callback policy from the AgentCore execution role
#   2. deletes the SAM stack (state machines, lambdas, IAM, log groups)
#   3. destroys the AgentCore runtime (runtime, memory, role, S3 artifacts)
#
# Usage:
#   ./destroy.sh             # asks for confirmation
#   ./destroy.sh --yes       # no prompt (CI / automation)
#   ./destroy.sh --keep-agent  # does NOT destroy the agent (only the SAM stack)
#
set -euo pipefail

export AWS_REGION="us-east-1"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AGENTCORE_SUPPRESS_RECOMMENDATION=1

STACK="doc-pipeline"
ROOT="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="$ROOT/agentcore"
AGENT_CFG="$AGENT_DIR/.bedrock_agentcore.yaml"

ASSUME_YES=false
KEEP_AGENT=false
for arg in "$@"; do
  case "$arg" in
    --yes|-y)    ASSUME_YES=true ;;
    --keep-agent) KEEP_AGENT=true ;;
  esac
done

c_ok()   { printf "\033[32m✓\033[0m %s\n" "$1"; }
c_info() { printf "\033[36m▶\033[0m %s\n" "$1"; }
c_warn() { printf "\033[33m! %s\033[0m\n" "$1"; }
c_err()  { printf "\033[31m✗ %s\033[0m\n" "$1" >&2; }

# credentials
aws sts get-caller-identity >/dev/null 2>&1 || { c_err "AWS credentials not configured."; exit 1; }
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

echo "About to REMOVE the document pipeline resources:"
echo "  - SAM stack         : $STACK"
echo "  - Callback policy   : detached from the AgentCore role"
[[ "$KEEP_AGENT" == "false" ]] && echo "  - AgentCore runtime : destroyed (runtime, memory, role, S3)"
echo "  Account: $ACCOUNT ($AWS_REGION)"
echo

if [[ "$ASSUME_YES" != "true" ]]; then
  read -r -p "Confirm destruction? [y/N] " resp
  [[ "$resp" == "y" || "$resp" == "Y" ]] || { echo "Cancelled."; exit 0; }
fi
echo

# ---------------------------------------------------------------------------
# 1. Detach the callback policy from the AgentCore role (before deleting the stack)
# ---------------------------------------------------------------------------
CALLBACK_POLICY=$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='AgentCallbackPolicyArn'].OutputValue" \
  --output text 2>/dev/null || true)

AGENT_ROLE_NAME=""
if [[ -f "$AGENT_CFG" ]]; then
  AGENT_ROLE_NAME=$(python3 - "$AGENT_CFG" << 'PY'
import sys, re
txt = open(sys.argv[1]).read()
for m in re.finditer(r'execution_role:\s*(\S+)', txt):
    v = m.group(1)
    if v.startswith("arn:"):
        print(v.split("/")[-1]); break
PY
)
fi

if [[ -n "$CALLBACK_POLICY" && "$CALLBACK_POLICY" != "None" && -n "$AGENT_ROLE_NAME" ]]; then
  c_info "Detaching callback policy from role $AGENT_ROLE_NAME..."
  aws iam detach-role-policy --role-name "$AGENT_ROLE_NAME" \
    --policy-arn "$CALLBACK_POLICY" >/dev/null 2>&1 \
    && c_ok "Policy detached" \
    || c_warn "Policy was already detached (or role does not exist)"
else
  c_warn "Could not find policy/role to detach (stack or config missing) — continuing"
fi
echo

# ---------------------------------------------------------------------------
# 2. Delete the SAM stack
# ---------------------------------------------------------------------------
if aws cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1; then
  c_info "Deleting SAM stack $STACK..."
  ( cd "$ROOT" && sam delete --stack-name "$STACK" --region "$AWS_REGION" --no-prompts >/dev/null )
  c_ok "Stack deleted"
else
  c_warn "Stack $STACK does not exist — nothing to delete"
fi
echo

# ---------------------------------------------------------------------------
# 3. Destroy the AgentCore runtime
# ---------------------------------------------------------------------------
if [[ "$KEEP_AGENT" == "true" ]]; then
  c_warn "--keep-agent: AgentCore runtime preserved"
elif [[ -f "$AGENT_CFG" ]]; then
  c_info "Destroying the AgentCore runtime..."
  ( cd "$AGENT_DIR" && yes | agentcore destroy >/dev/null 2>&1 ) \
    && c_ok "AgentCore destroyed" \
    || c_warn "agentcore destroy reported an error (it may have already been removed)"
else
  c_warn "Agent config missing — nothing to destroy in AgentCore"
fi
echo

c_ok "TEARDOWN COMPLETE"
c_warn "Reminder: if you raised X-Ray Transaction Search to 100%, revert it with:"
echo "    aws xray update-indexing-rule --name Default \\"
echo "      --rule '{\"Probabilistic\":{\"DesiredSamplingPercentage\":1.0}}' --region $AWS_REGION"
