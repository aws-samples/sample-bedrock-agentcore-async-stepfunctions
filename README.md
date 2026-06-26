# PoC flow-credi — Pipeline de Documentos com Bedrock AgentCore

> **Objetivo da demo:** validar documentos de financiamento imobiliário com um agente do
> **Bedrock AgentCore** (~15s de processamento) dentro de um pipeline do **Step Functions**,
> mostrando como **não desperdiçar custo de Lambda** enquanto o agente trabalha.

Demonstra, com infraestrutura como código (AWS SAM), **duas estratégias** para integrar um
agente do Bedrock AgentCore a um pipeline do Step Functions sem manter uma Lambda bloqueada
durante o processamento do agente.

O projeto deploya **duas state machines** que fazem a mesma coisa por caminhos diferentes,
para comparar lado a lado:

| Estratégia | State machine | Como chama o AgentCore |
|---|---|---|
| **A — com Lambda** | `flow-credi-document-pipeline` | Lambda dispatcher + `lambda:invoke.waitForTaskToken` (assíncrono) |
| **B — direto** | `flow-credi-pipeline-direct` | `aws-sdk:bedrockagentcore:invokeAgentRuntime` — **sem Lambda** (síncrono) |

---

## Estratégia A — Lambda + `waitForTaskToken` (assíncrono)

A chamada ao AgentCore acontece no branch **Validate** do `OrganizeAndValidateParallel`
(ao lado do `Organize`). O branch tem duas Lambdas com o agente no meio.

```
StartExecution
   │
   ▼ Step Functions: flow-credi-document-pipeline (STANDARD)
   Extract     Lambda · sleep 2s
   Identify    Lambda · sleep 2s · decide flags (NÃO chama o agente)
   RouteAfterIdentify (Choice)
    ├─ shouldOrganize && shouldValidate → OrganizeAndValidateParallel
    │     ┌─ branch Organize ──┐   ┌─ branch Validate ─────────────────────────┐
    │     │ Organize (sleep 2s)│   │ ValidateDispatch  (Lambda, waitForTaskToken)│
    │     │                    │   │   → invoca o AgentCore e RETORNA (morre ~5s)│
    │     │                    │   │   → o branch DORME sem custo                │
    │     │                    │   │        ▼ (AgentCore valida ~15-25s)         │
    │     │                    │   │   SendTaskSuccess ← tool concluir_validacao │
    │     │                    │   │ AgentCoreValidacao  (Pass, marcador visual) │
    │     │                    │   │ ValidateResult    (Lambda) processa veredito│
    │     └────────────────────┘   └─────────────────────────────────────────────┘
    ├─ shouldOrganize → OrganizeSolo  (Lambda · sleep 2s)
    ├─ shouldValidate → ValidateSolo  (Lambda · sleep 2s)
    └─ default → PipelineCompleted
   (erros) ─Catch─> PipelineFailed
```

- O agente roda em modo **assíncrono** (`@app.async_task`): o entrypoint retorna na hora e
  o trabalho de ~15s acontece em background; ao concluir, a tool `concluir_validacao` chama
  `SendTaskSuccess(taskToken)` e **acorda** o Step Functions.
- A Lambda `ValidateDispatch` só repassa o token e morre — **não fica esperando o agente**.

**Quando usar:** processos longos (até 8h de agente), múltiplos agentes em paralelo, ou
quando você quer desacoplar e não pagar nada durante a espera.

---

## Estratégia B — chamada direta do Step Functions (síncrono)

O Step Functions chama o AgentCore **diretamente**, via SDK integration, sem Lambda
nenhuma no meio.

```
StartExecution
   │
   ▼ Step Functions: flow-credi-pipeline-direct (STANDARD)
   Extract         Lambda · sleep 2s
   Identify        Lambda · sleep 2s · decide flags
   ValidateDireto  Task  →  arn:aws:states:::aws-sdk:bedrockagentcore:invokeAgentRuntime
                            (request-response: o SFN espera o agente ~15-25s e
                             recebe o veredito DIRETO no resultado do step)
   ParseAgentResponse  (Pass: Response string → JSON)
   ExtrairVeredito     (Pass: expõe $.validation)
   PipelineCompleted
```

- O agente roda em modo **síncrono** (sem `taskToken`): valida e **retorna o veredito no
  próprio payload**. O mesmo runtime atende aos dois modos — ele decide pela presença ou não
  do `taskToken` no evento.
- **Sem Lambda, zero código de cola.** Mais simples de ler no Graph view.

**Quando usar:** agente responde rápido (a chamada síncrona tem limite de ~15 min), pipeline
simples, e você aceita pagar o tempo do *step* enquanto o agente responde.

---

## Lambda x Direto — comparação

| | A — Lambda + waitForTaskToken | B — Direto (SDK integration) |
|---|---|---|
| Lambda no caminho do agente | sim (dispatcher), mas **morre cedo** | **nenhuma** |
| Modo do agente | assíncrono (callback) | síncrono (resposta no payload) |
| Custo durante o processamento | **zero** (SFN dormindo) | paga o tempo do *step* (Standard cobra por transição, não por espera; o custo real é o AgentCore) |
| Limite de duração | até 8h (agente) | ~15 min (chamada síncrona) |
| Complexidade | maior (Lambda + IAM callback + token) | mínima (1 Task state) |
| Lógica antes/depois do agente | explícita (`ValidateDispatch`/`ValidateResult`) | nos Pass states / outros steps |

> **Resumo:** para validações rápidas, **B (direto)** é mais simples. Para processos longos
> ou multiagente, **A (Lambda + waitForTaskToken)** garante custo zero durante a espera.

---

## Como provar que a Lambda NÃO ficou bloqueada (estratégia A)

Este é o ponto central da demo.

### Forma rápida — `evidencia-async.sh` (automatizado)

Gera a evidência completa para uma execução, cruzando a duração do *state* com o
`Billed Duration` da Lambda e os logs do agente:

```bash
./evidencia-async.sh                  # usa a última execução do pipeline (Lambda)
./evidencia-async.sh <executionArn>   # uma execução específica
```

Saída (exemplo real):

```
1) STEP FUNCTIONS — estado ValidateDispatch (waitForTaskToken)
   TaskSubmitted (retornou): 14:08:19   <- Lambda devolveu o controle
   TaskSucceeded (callback): 14:08:34   <- AgentCore acordou o fluxo
   >> DURACAO DO ESTADO     : 19.6s
   >> ESPERA PELO AGENTE    : 14.7s

2) LAMBDA — flow-credi-validate-dispatcher (CloudWatch REPORT)
   >> BILLED DURATION       : 4.8s   (tempo que a Lambda REALMENTE viveu/foi cobrada)

VEREDITO
   Estado durou ........ 19.6s
   Lambda cobrada ...... 4.8s
   Lambda OCIOSA evitada  14.9s (76%)
   ✅ PROVADO: a Lambda NAO ficou bloqueada esperando o AgentCore.

3) RUNTIME AGENTCORE — "modo ASSINCRONO / background task" + "Acordando via SendTaskSuccess"
```

A lógica: se a Lambda ficasse parada esperando (anti-padrão `await`), o `Billed Duration`
seria ~igual à duração do *state*. Como ela foi cobrada por **4,8s** mas o estado durou
**19,6s**, fica provado que ela morreu e o agente processou os ~15s restantes sem nenhuma
Lambda viva. (Numa execução da estratégia B, o script avisa que não há Lambda para "ficar
parada".)

### Forma manual — os mesmos dados em 3 lugares

### 1. Eventos do Step Functions (Event view / Table view)

No `ValidateDispatch`, o padrão `waitForTaskToken` gera **dois eventos separados**:

```
TaskStarted     ValidateDispatch   12:21:28   ← a Lambda começou
TaskSubmitted   ValidateDispatch   12:21:33   ← a Lambda RETORNOU e MORREU (~5s)
        (~20s de espera: agente trabalhando, NENHUMA Lambda viva)
TaskSucceeded   ValidateDispatch   12:21:52   ← o agente acordou o fluxo (SendTaskSuccess)
```

- A presença do **`TaskSubmitted` separado do `TaskSucceeded`** é a **assinatura** do modo
  assíncrono. Num invoke síncrono esse evento **não existe** (vai direto de `TaskStarted`
  para `TaskSucceeded`).
- O **gap entre `TaskSubmitted` e `TaskSucceeded`** (~20s) é o tempo em que o agente rodou
  com a Lambda **já encerrada**.

### 2. Duração real da Lambda (CloudWatch / log REPORT)

```bash
aws logs filter-log-events \
  --log-group-name /aws/lambda/flow-credi-validate-dispatcher \
  --filter-pattern "REPORT" --region us-east-1
```

O `Billed Duration` da `ValidateDispatch` é de **poucos segundos** (só o tempo de disparar o
agente), **não** os ~15-25s do processamento. Compare com o tempo do *state* `ValidateDispatch`
no Step Functions (muito maior) — a diferença é a espera sem Lambda.

### 3. Logs do runtime do AgentCore (a prova do lado do agente)

```bash
aws logs filter-log-events \
  --log-group-name /aws/bedrock-agentcore/runtimes/<AGENT_ID>-DEFAULT \
  --region us-east-1
```

Você verá, com timestamps que **casam** com o Step Functions:
- `"Iniciando validacao (modo ASSINCRONO / background task)"` — logo após a Lambda morrer
- `"Acordando Step Functions via SendTaskSuccess"` — bate com o `TaskSucceeded` (#)

> **Regra de bolso para a apresentação:** o *state* `ValidateDispatch` dura ~20-25s, mas o
> `Billed Duration` da Lambda é ~5s. Essa diferença, visível lado a lado, é a economia.

Na **estratégia B (direto)** não há Lambda no caminho, então a questão "bloqueou ou não"
nem se aplica — o que se paga é o tempo do *step* do Step Functions enquanto o AgentCore
responde (visível na duração do estado `ValidateDireto`).

---

## Estrutura do projeto

As Lambdas são **Node.js 22 (ESM)**; o agente do AgentCore é **Python**.

```
template.yaml                       SAM: 2 state machines + Lambdas + IAM + X-Ray
statemachine/
  pipeline.asl.json                 estratégia A (Lambda + waitForTaskToken)
  pipeline-direct.asl.json          estratégia B (AgentCore direto, SDK integration)
functions/                          Lambdas em Node.js (index.mjs)
  extract/                          OCR simulado (sleep 2s + logs)
  identify/                         classifica o doc e decide flags (sleep 2s)
  validate_dispatcher/              "ANTES" (estratégia A): invoca AgentCore e retorna na hora
                                    (@aws-sdk/client-bedrock-agentcore, bundled via esbuild)
  validate_result/                  "DEPOIS" (estratégia A): processa o veredito
  organize/                         branch Organize / OrganizeSolo (sleep 2s)
  validate/                         ValidateSolo (sleep 2s, sem agente)
agentcore/                          Agente em Python (dual-mode: async + síncrono)
  agent.py                          entrypoint + tool concluir_validacao
  Dockerfile  requirements.txt
events/                             payloads de teste
deploy.sh                           provisiona tudo (credencial + agente + SAM + callback)
destroy.sh                          remove tudo (stack + runtime do AgentCore)
run-demo.sh                         dispara execução e mostra timeline + resultado + trace
evidencia-async.sh                  prova que a Lambda não bloqueou (state x Billed Duration)
```

## Pré-requisitos

- AWS CLI, **AWS SAM CLI**, Docker, **Node.js 22** (Lambdas) e **Python 3.13** (agente)
- **Bedrock AgentCore Starter Toolkit**: `pip install bedrock-agentcore-starter-toolkit`
- Acesso ao modelo no Bedrock (ex.: Claude Sonnet) habilitado na conta/região
- Região sugerida: `us-east-1`

## Deploy / Teardown automatizados (recomendado)

```bash
./deploy.sh          # verifica credencial + ferramentas, deploya agente + SAM, anexa callback e testa
./destroy.sh         # remove TUDO (desanexa policy, deleta stack, destroi o runtime do AgentCore)
```

Flags úteis:
- `./deploy.sh --skip-agent` — reusa o agente já deployado (só atualiza o stack SAM)
- `./deploy.sh --no-test` — não roda a execução de validação no final
- `./destroy.sh --yes` — não pede confirmação · `--keep-agent` — preserva o runtime

O `deploy.sh` aborta cedo com mensagem clara se a **credencial AWS** estiver ausente/expirada
ou se faltar alguma ferramenta (aws, sam, docker, node, python3, agentcore).

## Deploy — passo a passo (manual)

> ⚠️ Os comandos abaixo criam recursos na sua conta AWS. Rode numa conta sandbox/dev.

### 1. Deployar o agente no AgentCore (gera o ARN do runtime)

```bash
cd agentcore
agentcore configure --entrypoint agent.py --name flowcredi
agentcore deploy            # build do container, push ECR e criação do runtime
# anote o Agent Runtime ARN no fim da saída
cd ..
```

### 2. Deployar as duas state machines (SAM), passando o ARN do agente

```bash
sam build
sam deploy --guided \
  --parameter-overrides AgentRuntimeArn="arn:aws:bedrock-agentcore:us-east-1:ACCOUNT:runtime/flowcredi-XXXX"
```

Outputs:
- `StateMachineArn` — estratégia A (Lambda + waitForTaskToken)
- `StateMachineDirectArn` — estratégia B (AgentCore direto)
- `AgentCallbackPolicyArn` — **anexe à execution role do AgentCore** (necessário só p/ a
  estratégia A, onde o agente chama `SendTaskSuccess`).

### 3. Conectar o callback (uma vez — necessário para a estratégia A)

```bash
aws iam attach-role-policy \
  --role-name <ROLE_DO_AGENTCORE_RUNTIME> \
  --policy-arn <AgentCallbackPolicyArn-do-output>
```

## Rodar a demo

```bash
./run-demo.sh            # estratégia A (Lambda + waitForTaskToken) — default
./run-demo.sh --direct   # estratégia B (AgentCore direto, sem Lambda)
./run-demo.sh --lambda   # idem A, explícito
```

O script dispara a execução, acompanha até o fim e imprime: a **timeline dos estados com
duração**, o **veredito do agente** (`source: agentcore`) e o **trace ID do X-Ray**.

## Observabilidade

- **X-Ray**: ativo nas Lambdas (`Tracing: Active`) e nas state machines (`Tracing.Enabled`).
  No **Service Map**/waterfall dá para ver o nó do AgentCore e o tempo de espera.
- **Logs estruturados**: cada Lambda Node.js emite JSON (`console.log`) com início/fim e duração.
- **Step Functions logs**: `ALL` em `/aws/vendedlogs/states/flow-credi-document-pipeline`
  e `/aws/vendedlogs/states/flow-credi-pipeline-direct`.
- **AgentCore**: logs em `/aws/bedrock-agentcore/runtimes/*`.

> Nota: a conta está com **X-Ray Transaction Search** (destino CloudWatch Logs). Os traces
> ficam em `aws/spans`; a busca por trace ID depende do sampling (subido para 100% durante a
> demo). Veja o waterfall na seção **Spans** da página do trace.

## Notas de design

- **Por que a estratégia A usa `lambda:invoke.waitForTaskToken` e não chama o AgentCore
  direto?** É a forma de obter **custo zero durante a espera** e suportar processos longos
  (até 8h). O Step Functions também tem integração direta (estratégia B), porém síncrona
  (~15 min) — por isso mantemos as duas para comparar.
- **`TimeoutSeconds`/`HeartbeatSeconds`** no `ValidateDispatch` evitam execução presa caso o
  agente nunca chame o callback.
- **Agente dual-mode:** o mesmo `agent.py` atende às duas state machines — com `taskToken`
  roda assíncrono (callback); sem `taskToken` roda síncrono (veredito no payload).
- **Roteamento da demo:** o documento de exemplo contém "CONTRATO/MATRICULA/FINANCIAMENTO",
  então o Identify marca `shouldOrganize=true` E `shouldValidate=true` e a estratégia A segue
  pelo `OrganizeAndValidateParallel` (Validate ao lado do Organize).
```
