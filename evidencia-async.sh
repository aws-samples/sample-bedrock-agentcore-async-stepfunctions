#!/usr/bin/env bash
#
# evidencia-async.sh — dado uma execucao do Step Functions, gera a EVIDENCIA de
# que a Lambda dispatcher NAO ficou bloqueada esperando o AgentCore.
#
# A prova e o contraste entre dois numeros:
#   (1) duracao do STATE ValidateDispatch no Step Functions  (tempo total ate o
#       agente responder via callback — inclui a espera)
#   (2) Billed Duration da LAMBDA dispatcher no CloudWatch    (tempo que a Lambda
#       REALMENTE viveu e foi cobrada)
# Se a Lambda ficasse bloqueada esperando, (1) ~ (2). A evidencia e que (2) << (1).
#
# Tambem cruza com os logs do runtime do AgentCore (inicio async + callback).
#
# Uso:
#   ./evidencia-async.sh                      # usa a ultima execucao do pipeline (Lambda)
#   ./evidencia-async.sh <executionArn>       # uma execucao especifica
#
set -euo pipefail

export AWS_REGION="us-east-1"
export AWS_DEFAULT_REGION="$AWS_REGION"

SM_ARN="arn:aws:states:${AWS_REGION}:$(aws sts get-caller-identity --query Account --output text):stateMachine:flow-credi-document-pipeline"
DISPATCHER_LG="/aws/lambda/flow-credi-validate-dispatcher"

EXEC_ARN="${1:-}"
if [[ -z "$EXEC_ARN" ]]; then
  EXEC_ARN=$(aws stepfunctions list-executions --state-machine-arn "$SM_ARN" \
    --max-results 1 --query "executions[0].executionArn" --output text)
fi
[[ "$EXEC_ARN" == arn:* ]] || { echo "ERRO: execution ARN invalido: $EXEC_ARN" >&2; exit 1; }

echo "Execucao analisada:"
echo "  $EXEC_ARN"
echo

aws stepfunctions get-execution-history --execution-arn "$EXEC_ARN" --output json \
  > /tmp/ev_hist.json

# nome do request id da Lambda dispatcher (para casar com o log REPORT)
python3 - "$DISPATCHER_LG" << 'PY'
import json, subprocess, sys
from datetime import datetime, timezone

h = json.load(open('/tmp/ev_hist.json'))
dispatcher_lg = sys.argv[1]

def ts(ev): return datetime.fromisoformat(ev['timestamp'].replace('Z','+00:00'))

# ---- (1) duracao do STATE ValidateDispatch ----
# Percorre em ordem; so coleta eventos de Task ENTRE o entered e o exited do
# ValidateDispatch, garantindo started < submitted < succeeded.
ent = exi = started = submitted = succeeded = None
dentro = False
for ev in h['events']:
    d = ev.get('stateEnteredEventDetails')
    if d and d.get('name') == 'ValidateDispatch':
        ent = ts(ev); dentro = True
        continue
    de = ev.get('stateExitedEventDetails')
    if de and de.get('name') == 'ValidateDispatch':
        exi = ts(ev); dentro = False
        continue
    if dentro:
        t = ev['type']
        if t == 'TaskStarted'   and started   is None: started   = ts(ev)
        if t == 'TaskSubmitted' and submitted is None: submitted = ts(ev)
        # o TaskSucceeded que importa e o que ocorre DEPOIS do TaskSubmitted
        # (o callback do agente). Ignora qualquer TaskSucceeded anterior.
        if t == 'TaskSucceeded' and submitted is not None and succeeded is None:
            succeeded = ts(ev)

if not ent:
    print("Esta execucao nao tem o estado 'ValidateDispatch' (talvez seja a pipeline DIRETA,")
    print("que chama o AgentCore sem Lambda — nesse caso nao ha Lambda para 'ficar parada').")
    raise SystemExit(0)

state_dur = (exi - ent).total_seconds() if exi else None
wait_gap  = (succeeded - submitted).total_seconds() if (submitted and succeeded) else None

print("="*68)
print("1) STEP FUNCTIONS — estado ValidateSDispatch (waitForTaskToken)".replace("SD","D"))
print("="*68)
def hhmmss(d): return d.strftime('%H:%M:%S.%f')[:-3] if d else '—'
print(f"  Entrou no estado        : {hhmmss(ent)}")
print(f"  TaskStarted (Lambda)    : {hhmmss(started)}")
print(f"  TaskSubmitted (retornou): {hhmmss(submitted)}   <- Lambda devolveu o controle")
print(f"  TaskSucceeded (callback): {hhmmss(succeeded)}   <- AgentCore acordou o fluxo")
print(f"  Saiu do estado          : {hhmmss(exi)}")
if state_dur is not None:
    print(f"  >> DURACAO DO ESTADO     : {state_dur:6.1f}s  (Step Functions esperando)")
if wait_gap is not None:
    print(f"  >> ESPERA PELO AGENTE    : {wait_gap:6.1f}s  (entre TaskSubmitted e TaskSucceeded)")
print()

# ---- (2) Billed Duration da LAMBDA dispatcher ----
# janela: ao redor do TaskStarted
start_ms = int((started.timestamp() - 60) * 1000) if started else int((ent.timestamp()-60)*1000)
end_ms   = int((succeeded.timestamp() + 60) * 1000) if succeeded else int((ent.timestamp()+180)*1000)

raw = subprocess.run([
    "aws","logs","filter-log-events",
    "--log-group-name", dispatcher_lg,
    "--start-time", str(start_ms), "--end-time", str(end_ms),
    "--filter-pattern", "REPORT",
    "--query","events[].message","--output","json"
], capture_output=True, text=True).stdout.strip()

print("="*68)
print("2) LAMBDA — flow-credi-validate-dispatcher (CloudWatch REPORT)")
print("="*68)
billed = None
import re
messages = []
try:
    messages = json.loads(raw) if raw else []
except Exception:
    messages = [raw]

# procura, em qualquer mensagem REPORT, a que tem Billed Duration
report_line = next((m for m in messages if "Billed Duration" in m), None)
if report_line:
    mb = re.search(r'Billed Duration:\s*([\d.]+)\s*ms', report_line)
    md = re.search(r'\tDuration:\s*([\d.]+)\s*ms', report_line) or \
         re.search(r'\bDuration:\s*([\d.]+)\s*ms', report_line)
    if md:
        print(f"  Duration         : {float(md.group(1))/1000.0:6.1f}s")
    if mb:
        billed = float(mb.group(1))/1000.0
        print(f"  >> BILLED DURATION: {billed:6.1f}s  (tempo que a Lambda REALMENTE viveu/foi cobrada)")
else:
    print("  (sem log REPORT com 'Billed Duration' na janela — Lambda pode nao ter logado ainda)")
print()

# ---- VEREDITO ----
print("="*68)
print("VEREDITO")
print("="*68)
if state_dur is not None and billed is not None:
    economia = state_dur - billed
    pct = (economia/state_dur*100) if state_dur else 0
    print(f"  Estado durou ............. {state_dur:6.1f}s")
    print(f"  Lambda cobrada ........... {billed:6.1f}s")
    print(f"  Lambda OCIOSA evitada .... {economia:6.1f}s  ({pct:.0f}% do tempo)")
    print()
    if billed < state_dur * 0.6:
        print("  ✅ PROVADO: a Lambda NAO ficou bloqueada esperando o AgentCore.")
        print(f"     Ela viveu {billed:.1f}s e morreu; o agente processou os outros")
        print(f"     ~{economia:.0f}s com NENHUMA Lambda viva (Step Functions dormindo).")
        print("     No anti-padrao (await), a Lambda seria cobrada pelos ~{:.0f}s inteiros.".format(state_dur))
    else:
        print("  ⚠️  Billed Duration proximo da duracao do estado — investigar.")
else:
    print("  Dados insuficientes para o comparativo (veja acima).")
PY

echo
echo "3) RUNTIME AGENTCORE — prova do lado do agente (inicio async + callback)"
echo "===================================================================="
AGENT_ID=$(aws bedrock-agentcore-control list-agent-runtimes \
  --query "agentRuntimes[?contains(agentRuntimeName,'flowcredi')].agentRuntimeId | [0]" --output text 2>/dev/null || true)
if [[ -n "$AGENT_ID" && "$AGENT_ID" != "None" ]]; then
  LG="/aws/bedrock-agentcore/runtimes/${AGENT_ID}-DEFAULT"
  NOW_MS=$(( $(date +%s) * 1000 ))
  # sem filter-pattern (multi-stream); filtramos via grep localmente
  aws logs filter-log-events --log-group-name "$LG" \
    --start-time $(( NOW_MS - 1800000 )) \
    --query "events[].message" --output json 2>/dev/null \
    | python3 -c "
import json,sys,re
try: msgs=json.load(sys.stdin)
except: msgs=[]
hits=[m.strip() for m in msgs if re.search(r'ASSINCRONO|background async|SendTaskSuccess', m)]
for m in hits[-3:]:
    print('  '+m[:140])
if not hits: print('  (logs do agente nao encontrados na janela)')
"
else
  echo "  (runtime flowcredi nao encontrado)"
fi
