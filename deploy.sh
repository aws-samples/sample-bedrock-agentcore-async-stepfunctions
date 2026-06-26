#!/usr/bin/env bash
#
# deploy.sh — provisiona TODA a PoC flow-credi do zero:
#   1. verifica credencial e ferramentas
#   2. deploya o agente no Bedrock AgentCore (configure + deploy)
#   3. deploya o stack SAM (2 state machines + lambdas + IAM + X-Ray)
#   4. anexa a managed policy de callback a execution role do AgentCore
#   5. valida com uma execucao de teste (opcional)
#
# Uso:
#   ./deploy.sh                # deploy completo
#   ./deploy.sh --skip-agent   # NAO redeploya o agente (reaproveita o existente)
#   ./deploy.sh --no-test      # nao roda a execucao de validacao no final
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
export AWS_REGION="us-east-1"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AGENTCORE_SUPPRESS_RECOMMENDATION=1

STACK="flow-credi-poc"
AGENT_NAME="flowcredi"
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
# 1. Pre-flight: ferramentas + credencial
# ---------------------------------------------------------------------------
c_info "Verificando ferramentas..."
for bin in aws sam docker node python3 agentcore; do
  command -v "$bin" >/dev/null 2>&1 || die "Ferramenta nao encontrada no PATH: $bin"
done
docker info >/dev/null 2>&1 || die "Docker nao esta rodando (necessario para o build do agente)."
c_ok "Ferramentas presentes (aws, sam, docker, node, python3, agentcore)"

c_info "Verificando credencial AWS..."
CALLER=$(aws sts get-caller-identity --output json 2>/dev/null) \
  || die "Credencial AWS nao configurada / expirada. Rode 'aws configure' ou exporte as chaves."
ACCOUNT=$(echo "$CALLER" | python3 -c "import json,sys;print(json.load(sys.stdin)['Account'])")
ARN=$(echo "$CALLER" | python3 -c "import json,sys;print(json.load(sys.stdin)['Arn'])")
c_ok "Credencial OK — conta $ACCOUNT em $AWS_REGION"
echo "    Identidade: $ARN"
echo

# ---------------------------------------------------------------------------
# 2. Agente no Bedrock AgentCore
# ---------------------------------------------------------------------------
if [[ "$SKIP_AGENT" == "false" ]]; then
  c_info "Deployando o agente no Bedrock AgentCore (pode levar alguns minutos)..."
  ( cd "$AGENT_DIR"
    if [[ ! -f .bedrock_agentcore.yaml ]]; then
      agentcore configure --entrypoint agent.py --name "$AGENT_NAME" \
        --region "$AWS_REGION" --non-interactive >/dev/null
    fi
    agentcore deploy >/dev/null )
  c_ok "Agente deployado"
else
  c_info "--skip-agent: reaproveitando o agente existente"
fi

# extrai ARN e execution role do config do agente
[[ -f "$AGENT_CFG" ]] || die "Config do agente nao encontrado ($AGENT_CFG). Rode sem --skip-agent."
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
# pega o primeiro execution_role que seja um ARN (ignora "null")
for m in re.finditer(r'execution_role:\s*(\S+)', txt):
    v = m.group(1)
    if v.startswith("arn:"):
        print(v); break
PY
)
[[ "$AGENT_ARN" == arn:* ]]  || die "Nao consegui extrair o agent_arn do config do agente."
[[ "$AGENT_ROLE" == arn:* ]] || die "Nao consegui extrair a execution_role do agente."
AGENT_ROLE_NAME="${AGENT_ROLE##*/}"
c_ok "Agent ARN : $AGENT_ARN"
c_ok "Exec role : $AGENT_ROLE_NAME"
echo

# ---------------------------------------------------------------------------
# 3. Stack SAM (2 state machines + lambdas)
# ---------------------------------------------------------------------------
c_info "Build SAM..."
( cd "$ROOT" && sam build >/dev/null ) || die "sam build falhou"
c_ok "Build concluido"

c_info "Deploy SAM (stack $STACK)..."
( cd "$ROOT" && sam deploy \
    --stack-name "$STACK" --region "$AWS_REGION" \
    --capabilities CAPABILITY_NAMED_IAM --resolve-s3 \
    --no-confirm-changeset --no-fail-on-empty-changeset \
    --parameter-overrides AgentRuntimeArn="$AGENT_ARN" >/dev/null ) \
  || die "sam deploy falhou"
c_ok "Stack deployado"

# le outputs
get_out() {
  aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
SM_LAMBDA=$(get_out StateMachineArn)
SM_DIRECT=$(get_out StateMachineDirectArn)
CALLBACK_POLICY=$(get_out AgentCallbackPolicyArn)
echo

# ---------------------------------------------------------------------------
# 4. Anexa a policy de callback a execution role do agente
# ---------------------------------------------------------------------------
c_info "Anexando policy de callback a role do AgentCore..."
aws iam attach-role-policy --role-name "$AGENT_ROLE_NAME" \
  --policy-arn "$CALLBACK_POLICY" >/dev/null
c_ok "Policy de callback anexada ($CALLBACK_POLICY)"
echo

# ---------------------------------------------------------------------------
# 5. Resumo + teste opcional
# ---------------------------------------------------------------------------
c_ok "DEPLOY COMPLETO"
echo "  Conta            : $ACCOUNT ($AWS_REGION)"
echo "  Agent runtime    : $AGENT_ARN"
echo "  Pipeline (Lambda): $SM_LAMBDA"
echo "  Pipeline (direto): $SM_DIRECT"
echo

if [[ "$RUN_TEST" == "true" ]]; then
  c_info "Rodando execucao de validacao (estrategia A — Lambda)..."
  "$ROOT/run-demo.sh" --lambda || c_err "teste falhou (veja o console)"
fi
