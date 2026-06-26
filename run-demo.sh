#!/usr/bin/env bash
#
# run-demo.sh — dispara uma nova execucao do pipeline flow-credi e acompanha
# ate o fim, imprimindo a timeline (com o gap assincrono do AgentCore), o
# resultado do agente e o trace ID do X-Ray.
#
# Uso:
#   ./run-demo.sh                 # roda e acompanha
#   ./run-demo.sh --no-wait       # so dispara e sai (nao espera terminar)
#
set -euo pipefail

# Regiao onde o stack esta deployado. Forcamos us-east-1 (ignora AWS_REGION do
# ambiente, que pode apontar para outra regiao). Ajuste aqui se mudar de regiao.
export AWS_REGION="us-east-1"
export AWS_DEFAULT_REGION="$AWS_REGION"

STACK="flow-credi-poc"
INPUT_FILE="$(dirname "$0")/events/start-execution.json"
WAIT=true
# Qual pipeline rodar: "lambda" (default, waitForTaskToken + Lambda) ou
# "direct" (AgentCore chamado direto do Step Functions, sem Lambda).
PIPELINE="lambda"
OUTPUT_KEY="StateMachineArn"
for arg in "$@"; do
  case "$arg" in
    --no-wait) WAIT=false ;;
    --direct)  PIPELINE="direct"; OUTPUT_KEY="StateMachineDirectArn" ;;
    --lambda)  PIPELINE="lambda"; OUTPUT_KEY="StateMachineArn" ;;
  esac
done
echo "Pipeline: $PIPELINE"

# --- descobre o ARN da state machine pelo output do stack -------------------
SM_ARN=$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='$OUTPUT_KEY'].OutputValue" \
  --output text 2>/dev/null || true)

if [[ -z "$SM_ARN" || "$SM_ARN" == "None" ]]; then
  echo "ERRO: nao achei a StateMachineArn no stack '$STACK' em $AWS_REGION." >&2
  echo "      O stack esta deployado? (sam deploy)" >&2
  exit 1
fi

NAME="demo-$(date +%Y%m%d-%H%M%S)"
echo "State machine : $SM_ARN"
echo "Execucao      : $NAME"
echo "Input         : $INPUT_FILE"
echo

# --- dispara ----------------------------------------------------------------
EXEC_ARN=$(aws stepfunctions start-execution \
  --state-machine-arn "$SM_ARN" \
  --name "$NAME" \
  --input "file://$INPUT_FILE" \
  --query executionArn --output text)

echo "Execucao iniciada:"
echo "  $EXEC_ARN"
echo
echo "Console (Step Functions):"
echo "  https://$AWS_REGION.console.aws.amazon.com/states/home?region=$AWS_REGION#/v2/executions/details/$EXEC_ARN"
echo

if [[ "$WAIT" == "false" ]]; then
  exit 0
fi

# --- acompanha ate terminar -------------------------------------------------
echo -n "Aguardando conclusao"
STATUS="RUNNING"
for _ in $(seq 1 40); do
  STATUS=$(aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" \
    --query status --output text)
  [[ "$STATUS" != "RUNNING" ]] && break
  echo -n "."
  sleep 3
done
echo
echo "Status final: $STATUS"
echo

# --- timeline dos estados (tempo de cada um) --------------------------------
echo "=== Timeline (estados x duracao) ==="
aws stepfunctions get-execution-history --execution-arn "$EXEC_ARN" --output json \
  > /tmp/flowcredi_hist.json
python3 - << 'PY'
import json
from datetime import datetime
h = json.load(open('/tmp/flowcredi_hist.json'))

def ts(ev): return datetime.fromisoformat(ev['timestamp'].replace('Z','+00:00'))

# tempo de entrada/saida por estado
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
        marca = ''
        if nm in ('ValidateDispatch','ValidateDireto'):
            marca = '  <<< chamada ao AgentCore'
        print(f"  +{ini:5.1f}s  dur {dur:5.1f}s  {nm}{marca}")
PY
echo

# --- resultado do agente ----------------------------------------------------
echo "=== Resultado devolvido pelo AgentCore (validation) ==="
aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" \
  --query output --output text > /tmp/flowcredi_out.json 2>/dev/null || true
python3 - << 'PY'
import json
try:
    o = json.load(open('/tmp/flowcredi_out.json'))
except Exception:
    print("  (sem output — execucao pode ter falhado)"); raise SystemExit
# output do Parallel e uma lista de branches; procura o que tem validation
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
    print("  aprovado:", val.get('aprovado'))
    print("  resumo  :", val.get('resumo'))
else:
    print("  (validation nao encontrado no output)")
PY
echo

# --- trace X-Ray ------------------------------------------------------------
echo "=== Trace X-Ray ==="
START=$(date -v-3M +%s 2>/dev/null || date -d '3 minutes ago' +%s)
NOWS=$(date +%s)
aws xray get-trace-summaries --start-time "$START" --end-time "$NOWS" \
  --query "reverse(sort_by(TraceSummaries,&Duration))[0].Id" --output text 2>/dev/null \
  | sed 's/^/  Trace ID: /' || echo "  (trace ainda indexando — tente em ~1 min)"
echo "  Console (Traces): https://$AWS_REGION.console.aws.amazon.com/cloudwatch/home?region=$AWS_REGION#xray:traces/query"
