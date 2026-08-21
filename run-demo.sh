#!/usr/bin/env bash
#
# run-demo.sh — starts a new execution of the document pipeline and follows it
# to the end, printing the timeline (with the AgentCore async gap), the agent
# result and the X-Ray trace ID.
#
# Usage:
#   ./run-demo.sh                 # runs and follows
#   ./run-demo.sh --no-wait       # only starts and exits (does not wait for completion)
#
set -euo pipefail

# Region where the stack is deployed. We force us-east-1 (ignoring AWS_REGION
# from the environment, which may point to another region). Adjust here if you
# change region.
export AWS_REGION="us-east-1"
export AWS_DEFAULT_REGION="$AWS_REGION"

STACK="doc-pipeline"
INPUT_FILE="$(dirname "$0")/events/start-execution.json"
WAIT=true
# Which pipeline to run: "lambda" (default, waitForTaskToken + Lambda),
# "direct" (AgentCore called directly from Step Functions, no Lambda) or
# "durable" (Pattern 3 — Lambda durable function, no Step Functions at all).
PIPELINE="lambda"
OUTPUT_KEY="StateMachineArn"
for arg in "$@"; do
  case "$arg" in
    --no-wait) WAIT=false ;;
    --direct)  PIPELINE="direct"; OUTPUT_KEY="StateMachineDirectArn" ;;
    --lambda)  PIPELINE="lambda"; OUTPUT_KEY="StateMachineArn" ;;
    --durable) PIPELINE="durable" ;;
  esac
done
echo "Pipeline: $PIPELINE"

# --- Pattern 3 (durable function) has no state machine — invoke the Lambda ---
if [[ "$PIPELINE" == "durable" ]]; then
  FN="doc-pipeline-durable"
  NAME="demo-$(date +%Y%m%d-%H%M%S)"
  echo "Durable function : $FN (qualifier: live)"
  echo "Execution name   : $NAME"
  echo "Input            : $INPUT_FILE"
  echo
  # Durable functions require a qualified identifier; async invoke (Event) queues
  # it and returns immediately. --durable-execution-name gives idempotency.
  aws lambda invoke \
    --function-name "$FN" --qualifier live \
    --invocation-type Event \
    --durable-execution-name "$NAME" \
    --cli-binary-format raw-in-base64-out \
    --payload "file://$INPUT_FILE" \
    /tmp/docpipeline_durable_invoke.json >/dev/null \
    || { echo "ERROR: invoke failed — is the stack deployed?" >&2; exit 1; }
  echo "Durable execution started (async). Watch progress in:"
  echo "  CloudWatch logs : /aws/lambda/$FN"
  echo "  AgentCore logs  : /aws/bedrock-agentcore/runtimes/*"
  echo
  echo "Inspect the durable execution (list needs a version number, not the alias):"
  echo "  VER=\$(aws lambda get-alias --function-name $FN --name live --query FunctionVersion --output text --region $AWS_REGION)"
  echo "  aws lambda list-durable-executions-by-function --function-name $FN:\$VER --region $AWS_REGION"
  exit 0
fi

# --- discover the state machine ARN from the stack output -------------------
SM_ARN=$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='$OUTPUT_KEY'].OutputValue" \
  --output text 2>/dev/null || true)

if [[ -z "$SM_ARN" || "$SM_ARN" == "None" ]]; then
  echo "ERROR: could not find StateMachineArn in stack '$STACK' in $AWS_REGION." >&2
  echo "       Is the stack deployed? (sam deploy)" >&2
  exit 1
fi

NAME="demo-$(date +%Y%m%d-%H%M%S)"
echo "State machine : $SM_ARN"
echo "Execution     : $NAME"
echo "Input         : $INPUT_FILE"
echo

# --- start ------------------------------------------------------------------
EXEC_ARN=$(aws stepfunctions start-execution \
  --state-machine-arn "$SM_ARN" \
  --name "$NAME" \
  --input "file://$INPUT_FILE" \
  --query executionArn --output text)

echo "Execution started:"
echo "  $EXEC_ARN"
echo
echo "Console (Step Functions):"
echo "  https://$AWS_REGION.console.aws.amazon.com/states/home?region=$AWS_REGION#/v2/executions/details/$EXEC_ARN"
echo

if [[ "$WAIT" == "false" ]]; then
  exit 0
fi

# --- follow until completion ------------------------------------------------
echo -n "Waiting for completion"
STATUS="RUNNING"
for _ in $(seq 1 40); do
  STATUS=$(aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" \
    --query status --output text)
  [[ "$STATUS" != "RUNNING" ]] && break
  echo -n "."
  sleep 3
done
echo
echo "Final status: $STATUS"
echo

# --- states timeline (duration of each) -------------------------------------
echo "=== Timeline (states x duration) ==="
aws stepfunctions get-execution-history --execution-arn "$EXEC_ARN" --output json \
  > /tmp/docpipeline_hist.json
python3 - << 'PY'
import json
from datetime import datetime
h = json.load(open('/tmp/docpipeline_hist.json'))

def ts(ev): return datetime.fromisoformat(ev['timestamp'].replace('Z','+00:00'))

# enter/exit time per state
enter, exit_ = {}, {}
order = []
for ev in h['events']:
    d = ev.get('stateEnteredEventDetails')
    if d:
        nm = d['name']
        if nm not in enter: enter[nm] = ts(ev); order.append(nm)
    de = ev.get('stateExitedEventDetails')
    if de: exit_[de['name']] = ts(ev)

if order:
    t0 = enter[order[0]]
    for nm in order:
        ini = (enter[nm]-t0).total_seconds()
        dur = (exit_.get(nm, enter[nm])-enter[nm]).total_seconds()
        mark = ''
        if nm in ('ValidateDispatch','ValidateDirect'):
            mark = '  <<< call to AgentCore'
        print(f"  +{ini:5.1f}s  dur {dur:5.1f}s  {nm}{mark}")
PY
echo

# --- agent result -----------------------------------------------------------
echo "=== Result returned by AgentCore (validation) ==="
aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" \
  --query output --output text > /tmp/docpipeline_out.json 2>/dev/null || true
python3 - << 'PY'
import json
try:
    o = json.load(open('/tmp/docpipeline_out.json'))
except Exception:
    print("  (no output — the execution may have failed)"); raise SystemExit
# the Parallel output is a list of branches; look for the one that has validation
val = None
def find_val(x):
    global val
    if isinstance(x, dict):
        if 'validation' in x: val = x['validation']
        for v in x.values(): find_val(v)
    elif isinstance(x, list):
        for v in x: find_val(v)
find_val(o)
if val:
    print("  source  :", val.get('source'))
    print("  approved:", val.get('approved'))
    print("  summary :", val.get('summary'))
else:
    print("  (validation not found in the output)")
PY
echo

# --- X-Ray trace ------------------------------------------------------------
echo "=== X-Ray trace ==="
START=$(date -v-3M +%s 2>/dev/null || date -d '3 minutes ago' +%s)
NOWS=$(date +%s)
aws xray get-trace-summaries --start-time "$START" --end-time "$NOWS" \
  --query "reverse(sort_by(TraceSummaries,&Duration))[0].Id" --output text 2>/dev/null \
  | sed 's/^/  Trace ID: /' || echo "  (trace still indexing — try again in ~1 min)"
echo "  Console (Traces): https://$AWS_REGION.console.aws.amazon.com/cloudwatch/home?region=$AWS_REGION#xray:traces/query"
