#!/usr/bin/env bash
#
# destroy.sh — remove TUDO que o deploy.sh criou:
#   1. desanexa a policy de callback da execution role do AgentCore
#   2. deleta o stack SAM (state machines, lambdas, IAM, log groups)
#   3. destroi o runtime do AgentCore (runtime, memoria, role, artefatos S3)
#
# Uso:
#   ./destroy.sh             # pede confirmacao
#   ./destroy.sh --yes       # nao pergunta (CI / automacao)
#   ./destroy.sh --keep-agent  # NAO destroi o agente (so o stack SAM)
#
set -euo pipefail

export AWS_REGION="us-east-1"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AGENTCORE_SUPPRESS_RECOMMENDATION=1

STACK="flow-credi-poc"
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

# credencial
aws sts get-caller-identity >/dev/null 2>&1 || { c_err "Credencial AWS nao configurada."; exit 1; }
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

echo "Vai REMOVER os recursos da PoC flow-credi:"
echo "  - Stack SAM         : $STACK"
echo "  - Policy de callback: desanexada da role do AgentCore"
[[ "$KEEP_AGENT" == "false" ]] && echo "  - AgentCore runtime : destruido (runtime, memoria, role, S3)"
echo "  Conta: $ACCOUNT ($AWS_REGION)"
echo

if [[ "$ASSUME_YES" != "true" ]]; then
  read -r -p "Confirmar destruicao? [y/N] " resp
  [[ "$resp" == "y" || "$resp" == "Y" ]] || { echo "Cancelado."; exit 0; }
fi
echo

# ---------------------------------------------------------------------------
# 1. Desanexar a policy de callback da role do AgentCore (antes de deletar o stack)
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
  c_info "Desanexando policy de callback da role $AGENT_ROLE_NAME..."
  aws iam detach-role-policy --role-name "$AGENT_ROLE_NAME" \
    --policy-arn "$CALLBACK_POLICY" >/dev/null 2>&1 \
    && c_ok "Policy desanexada" \
    || c_warn "Policy ja estava desanexada (ou role inexistente)"
else
  c_warn "Nao achei policy/role para desanexar (stack ou config ausente) — seguindo"
fi
echo

# ---------------------------------------------------------------------------
# 2. Deletar o stack SAM
# ---------------------------------------------------------------------------
if aws cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1; then
  c_info "Deletando stack SAM $STACK..."
  ( cd "$ROOT" && sam delete --stack-name "$STACK" --region "$AWS_REGION" --no-prompts >/dev/null )
  c_ok "Stack deletado"
else
  c_warn "Stack $STACK nao existe — nada a deletar"
fi
echo

# ---------------------------------------------------------------------------
# 3. Destruir o runtime do AgentCore
# ---------------------------------------------------------------------------
if [[ "$KEEP_AGENT" == "true" ]]; then
  c_warn "--keep-agent: runtime do AgentCore preservado"
elif [[ -f "$AGENT_CFG" ]]; then
  c_info "Destruindo o runtime do AgentCore..."
  ( cd "$AGENT_DIR" && yes | agentcore destroy >/dev/null 2>&1 ) \
    && c_ok "AgentCore destruido" \
    || c_warn "agentcore destroy reportou erro (pode ja ter sido removido)"
else
  c_warn "Config do agente ausente — nada a destruir no AgentCore"
fi
echo

c_ok "TEARDOWN COMPLETO"
c_warn "Lembrete: se voce subiu o X-Ray Transaction Search para 100%, reverta com:"
echo "    aws xray update-indexing-rule --name Default \\"
echo "      --rule '{\"Probabilistic\":{\"DesiredSamplingPercentage\":1.0}}' --region $AWS_REGION"
