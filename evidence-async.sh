#!/usr/bin/env bash
#
# evidence-async.sh — given a Step Functions execution, produces the EVIDENCE
# that the dispatcher Lambda did NOT stay blocked waiting for AgentCore.
#
# The proof is the contrast between two numbers:
#   (1) duration of the ValidateDispatch STATE in Step Functions  (total time
#       until the agent responds via callback — includes the wait)
#   (2) Billed Duration of the dispatcher LAMBDA in CloudWatch     (time the
#       Lambda ACTUALLY lived and was billed)
# If the Lambda stayed blocked waiting, (1) ~ (2). The evidence is that (2) << (1).
#
# It also cross-references the AgentCore runtime logs (async start + callback).
#
# Usage:
#   ./evidence-async.sh                      # uses the latest execution of the pipeline (Lambda)
#   ./evidence-async.sh <executionArn>       # a specific execution
#
set -euo pipefail

export AWS_REGION="us-east-1"
export AWS_DEFAULT_REGION="$AWS_REGION"

SM_ARN="arn:aws:states:${AWS_REGION}:$(aws sts get-caller-identity --query Account --output text):stateMachine:doc-pipeline"
DISPATCHER_LG="/aws/lambda/doc-pipeline-validate-dispatcher"

EXEC_ARN="${1:-}"
if [[ -z "$EXEC_ARN" ]]; then
  EXEC_ARN=$(aws stepfunctions list-executions --state-machine-arn "$SM_ARN" \
    --max-results 1 --query "executions[0].executionArn" --output text)
fi
[[ "$EXEC_ARN" == arn:* ]] || { echo "ERROR: invalid execution ARN: $EXEC_ARN" >&2; exit 1; }

echo "Execution analyzed:"
echo "  $EXEC_ARN"
echo

aws stepfunctions get-execution-history --execution-arn "$EXEC_ARN" --output json \
  > /tmp/ev_hist.json

# request id of the dispatcher Lambda (to match against the REPORT log)
python3 - "$DISPATCHER_LG" << 'PY'
import json, subprocess, sys
from datetime import datetime, timezone

h = json.load(open('/tmp/ev_hist.json'))
dispatcher_lg = sys.argv[1]

def ts(ev): return datetime.fromisoformat(ev['timestamp'].replace('Z','+00:00'))

# ---- (1) duration of the ValidateDispatch STATE ----
# Walk in order; only collect Task events BETWEEN the entered and the exited of
# ValidateDispatch, ensuring started < submitted < succeeded.
ent = exi = started = submitted = succeeded = None
inside = False
for ev in h['events']:
    d = ev.get('stateEnteredEventDetails')
    if d and d.get('name') == 'ValidateDispatch':
        ent = ts(ev); inside = True
        continue
    de = ev.get('stateExitedEventDetails')
    if de and de.get('name') == 'ValidateDispatch':
        exi = ts(ev); inside = False
        continue
    if inside:
        t = ev['type']
        if t == 'TaskStarted'   and started   is None: started   = ts(ev)
        if t == 'TaskSubmitted' and submitted is None: submitted = ts(ev)
        # the TaskSucceeded that matters is the one that occurs AFTER TaskSubmitted
        # (the agent callback). Ignore any earlier TaskSucceeded.
        if t == 'TaskSucceeded' and submitted is not None and succeeded is None:
            succeeded = ts(ev)

if not ent:
    print("This execution has no 'ValidateDispatch' state (it may be the DIRECT pipeline,")
    print("which calls AgentCore without a Lambda — in that case there is no Lambda to 'sit idle').")
    raise SystemExit(0)

state_dur = (exi - ent).total_seconds() if exi else None
wait_gap  = (succeeded - submitted).total_seconds() if (submitted and succeeded) else None

print("="*68)
print("1) STEP FUNCTIONS — ValidateDispatch state (waitForTaskToken)")
print("="*68)
def hhmmss(d): return d.strftime('%H:%M:%S.%f')[:-3] if d else '—'
print(f"  Entered state           : {hhmmss(ent)}")
print(f"  TaskStarted (Lambda)    : {hhmmss(started)}")
print(f"  TaskSubmitted (returned): {hhmmss(submitted)}   <- Lambda handed back control")
print(f"  TaskSucceeded (callback): {hhmmss(succeeded)}   <- AgentCore woke up the flow")
print(f"  Exited state            : {hhmmss(exi)}")
if state_dur is not None:
    print(f"  >> STATE DURATION        : {state_dur:6.1f}s  (Step Functions waiting)")
if wait_gap is not None:
    print(f"  >> WAIT FOR THE AGENT    : {wait_gap:6.1f}s  (between TaskSubmitted and TaskSucceeded)")
print()

# ---- (2) Billed Duration of the dispatcher LAMBDA ----
# window: around TaskStarted
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
print("2) LAMBDA — doc-pipeline-validate-dispatcher (CloudWatch REPORT)")
print("="*68)
billed = None
import re
messages = []
try:
    messages = json.loads(raw) if raw else []
except Exception:
    messages = [raw]

# look, in any REPORT message, for the one with Billed Duration
report_line = next((m for m in messages if "Billed Duration" in m), None)
if report_line:
    mb = re.search(r'Billed Duration:\s*([\d.]+)\s*ms', report_line)
    md = re.search(r'\tDuration:\s*([\d.]+)\s*ms', report_line) or \
         re.search(r'\bDuration:\s*([\d.]+)\s*ms', report_line)
    if md:
        print(f"  Duration         : {float(md.group(1))/1000.0:6.1f}s")
    if mb:
        billed = float(mb.group(1))/1000.0
        print(f"  >> BILLED DURATION: {billed:6.1f}s  (time the Lambda ACTUALLY lived/was billed)")
else:
    print("  (no REPORT log with 'Billed Duration' in the window — Lambda may not have logged yet)")
print()

# ---- VERDICT ----
print("="*68)
print("VERDICT")
print("="*68)
if state_dur is not None and billed is not None:
    savings = state_dur - billed
    pct = (savings/state_dur*100) if state_dur else 0
    print(f"  State lasted ............. {state_dur:6.1f}s")
    print(f"  Lambda billed ............ {billed:6.1f}s")
    print(f"  Lambda IDLE time avoided . {savings:6.1f}s  ({pct:.0f}% of the time)")
    print()
    if billed < state_dur * 0.6:
        print("  ✅ PROVEN: the Lambda did NOT stay blocked waiting for AgentCore.")
        print(f"     It lived {billed:.1f}s and died; the agent processed the other")
        print(f"     ~{savings:.0f}s with NO Lambda alive (Step Functions sleeping).")
        print("     In the anti-pattern (await), the Lambda would be billed for the whole ~{:.0f}s.".format(state_dur))
    else:
        print("  ⚠️  Billed Duration close to the state duration — investigate.")
else:
    print("  Not enough data for the comparison (see above).")
PY

echo
echo "3) AGENTCORE RUNTIME — proof from the agent side (async start + callback)"
echo "===================================================================="
AGENT_ID=$(aws bedrock-agentcore-control list-agent-runtimes \
  --query "agentRuntimes[?contains(agentRuntimeName,'docpipeline')].agentRuntimeId | [0]" --output text 2>/dev/null || true)
if [[ -n "$AGENT_ID" && "$AGENT_ID" != "None" ]]; then
  LG="/aws/bedrock-agentcore/runtimes/${AGENT_ID}-DEFAULT"
  NOW_MS=$(( $(date +%s) * 1000 ))
  # no filter-pattern (multi-stream); we filter with grep locally
  aws logs filter-log-events --log-group-name "$LG" \
    --start-time $(( NOW_MS - 1800000 )) \
    --query "events[].message" --output json 2>/dev/null \
    | python3 -c "
import json,sys,re
try: msgs=json.load(sys.stdin)
except: msgs=[]
hits=[m.strip() for m in msgs if re.search(r'ASYNCHRONOUS|background task|SendTaskSuccess', m)]
for m in hits[-3:]:
    print('  '+m[:140])
if not hits: print('  (agent logs not found in the window)')
"
else
  echo "  (docpipeline runtime not found)"
fi
