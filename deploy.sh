#!/usr/bin/env bash
#
# deploy.sh — provisions the WHOLE document pipeline from scratch:
#   1. checks credentials and tools
#   2. deploys the agent to Bedrock AgentCore (configure + deploy)
#   3. deploys the SAM stack (2 state machines + lambdas + IAM + X-Ray)
#   4. attaches the callback managed policy to the AgentCore execution role
#   5. validates with a test execution (optional)
#
# Usage:
#   ./deploy.sh                # full deploy
#   ./deploy.sh --skip-agent   # does NOT redeploy the agent (reuses the existing one)
#   ./deploy.sh --no-test      # does not run the validation execution at the end
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
export AWS_REGION="us-east-1"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AGENTCORE_SUPPRESS_RECOMMENDATION=1

STACK="doc-pipeline"
AGENT_NAME="docpipeline"
ROOT="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="$ROOT/agentcore"
AGENT_CFG="$AGENT_DIR/.bedrock_agentcore.yaml"

SKIP_AGENT=false
RUN_TEST=true
for arg in "$@"; do
  case "$arg" in
    --skip-agent) SKIP_AGENT=true ;;
    --no-test)    RUN_TEST=false ;;
  esac
done

c_ok()   { printf "\033[32m✓\033[0m %s\n" "$1"; }
c_info() { printf "\033[36m▶\033[0m %s\n" "$1"; }
c_err()  { printf "\033[31m✗ %s\033[0m\n" "$1" >&2; }
die()    { c_err "$1"; exit 1; }

# ---------------------------------------------------------------------------
# 1. Pre-flight: tools + credentials
# ---------------------------------------------------------------------------
c_info "Checking tools..."
for bin in aws sam docker node python3 agentcore; do
  command -v "$bin" >/dev/null 2>&1 || die "Tool not found in PATH: $bin"
done
docker info >/dev/null 2>&1 || die "Docker is not running (required to build the agent)."
c_ok "Tools present (aws, sam, docker, node, python3, agentcore)"

c_info "Checking AWS credentials..."
CALLER=$(aws sts get-caller-identity --output json 2>/dev/null) \
  || die "AWS credentials not configured / expired. Run 'aws configure' or export the keys."
ACCOUNT=$(echo "$CALLER" | python3 -c "import json,sys;print(json.load(sys.stdin)['Account'])")
ARN=$(echo "$CALLER" | python3 -c "import json,sys;print(json.load(sys.stdin)['Arn'])")
c_ok "Credentials OK — account $ACCOUNT in $AWS_REGION"
echo "    Identity: $ARN"
echo

# ---------------------------------------------------------------------------
# 2. Agent on Bedrock AgentCore
# ---------------------------------------------------------------------------
if [[ "$SKIP_AGENT" == "false" ]]; then
  c_info "Deploying the agent to Bedrock AgentCore (may take a few minutes)..."
  ( cd "$AGENT_DIR"
    if [[ ! -f .bedrock_agentcore.yaml ]]; then
      agentcore configure --entrypoint agent.py --name "$AGENT_NAME" \
        --region "$AWS_REGION" --non-interactive >/dev/null
    fi
    agentcore deploy >/dev/null )
  c_ok "Agent deployed"
else
  c_info "--skip-agent: reusing the existing agent"
fi

# extract ARN and execution role from the agent config
[[ -f "$AGENT_CFG" ]] || die "Agent config not found ($AGENT_CFG). Run without --skip-agent."
AGENT_ARN=$(python3 - "$AGENT_CFG" << 'PY'
import sys, re
txt = open(sys.argv[1]).read()
m = re.search(r'agent_arn:\s*(\S+)', txt)
print(m.group(1) if m else "")
PY
)
AGENT_ROLE=$(python3 - "$AGENT_CFG" << 'PY'
import sys, re
txt = open(sys.argv[1]).read()
# take the first execution_role that is an ARN (ignore "null")
for m in re.finditer(r'execution_role:\s*(\S+)', txt):
    v = m.group(1)
    if v.startswith("arn:"):
        print(v); break
PY
)
[[ "$AGENT_ARN" == arn:* ]]  || die "Could not extract agent_arn from the agent config."
[[ "$AGENT_ROLE" == arn:* ]] || die "Could not extract execution_role from the agent."
AGENT_ROLE_NAME="${AGENT_ROLE##*/}"
c_ok "Agent ARN : $AGENT_ARN"
c_ok "Exec role : $AGENT_ROLE_NAME"
echo

# ---------------------------------------------------------------------------
# 3. SAM stack (2 state machines + lambdas)
# ---------------------------------------------------------------------------
c_info "SAM build..."
( cd "$ROOT" && sam build >/dev/null ) || die "sam build failed"
c_ok "Build finished"

c_info "SAM deploy (stack $STACK)..."
( cd "$ROOT" && sam deploy \
    --stack-name "$STACK" --region "$AWS_REGION" \
    --capabilities CAPABILITY_NAMED_IAM --resolve-s3 \
    --no-confirm-changeset --no-fail-on-empty-changeset \
    --parameter-overrides AgentRuntimeArn="$AGENT_ARN" >/dev/null ) \
  || die "sam deploy failed"
c_ok "Stack deployed"

# read outputs
get_out() {
  aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
SM_LAMBDA=$(get_out StateMachineArn)
SM_DIRECT=$(get_out StateMachineDirectArn)
CALLBACK_POLICY=$(get_out AgentCallbackPolicyArn)
echo

# ---------------------------------------------------------------------------
# 4. Attach the callback policy to the agent execution role
# ---------------------------------------------------------------------------
c_info "Attaching callback policy to the AgentCore role..."
aws iam attach-role-policy --role-name "$AGENT_ROLE_NAME" \
  --policy-arn "$CALLBACK_POLICY" >/dev/null
c_ok "Callback policy attached ($CALLBACK_POLICY)"
echo

# ---------------------------------------------------------------------------
# 5. Summary + optional test
# ---------------------------------------------------------------------------
c_ok "DEPLOY COMPLETE"
echo "  Account          : $ACCOUNT ($AWS_REGION)"
echo "  Agent runtime    : $AGENT_ARN"
echo "  Pipeline (Lambda): $SM_LAMBDA"
echo "  Pipeline (direct): $SM_DIRECT"
echo

if [[ "$RUN_TEST" == "true" ]]; then
  c_info "Running validation execution (strategy A — Lambda)..."
  "$ROOT/run-demo.sh" --lambda || c_err "test failed (check the console)"
fi
