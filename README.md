# Document Pipeline with Bedrock AgentCore

> **Goal of the demo:** validate real estate financing documents with a
> **Bedrock AgentCore** agent (~15s of processing) inside a **Step Functions**
> pipeline, showing how to **not waste Lambda cost** while the agent works.

Demonstrates, with infrastructure as code (AWS SAM), **two strategies** for
integrating a Bedrock AgentCore agent into a Step Functions pipeline without
keeping a Lambda blocked during the agent's processing.

The project deploys **two state machines** that do the same thing via different
paths, so you can compare them side by side:

| Strategy | State machine | How it calls AgentCore |
|---|---|---|
| **A — with Lambda** | `doc-pipeline` | Lambda dispatcher + `lambda:invoke.waitForTaskToken` (asynchronous) |
| **B — direct** | `doc-pipeline-direct` | `aws-sdk:bedrockagentcore:invokeAgentRuntime` — **no Lambda** (synchronous) |

---

## Strategy A — Lambda + `waitForTaskToken` (asynchronous)

The AgentCore call happens in the **Validate** branch of
`OrganizeAndValidateParallel` (next to `Organize`). The branch has two Lambdas
with the agent in the middle.

```
StartExecution
   │
   ▼ Step Functions: doc-pipeline (STANDARD)
   Extract     Lambda · sleep 2s
   Identify    Lambda · sleep 2s · decides flags (does NOT call the agent)
   RouteAfterIdentify (Choice)
    ├─ shouldOrganize && shouldValidate → OrganizeAndValidateParallel
    │     ┌─ branch Organize ──┐   ┌─ branch Validate ─────────────────────────┐
    │     │ Organize (sleep 2s)│   │ ValidateDispatch  (Lambda, waitForTaskToken)│
    │     │                    │   │   → invokes AgentCore and RETURNS (dies ~5s)│
    │     │                    │   │   → the branch SLEEPS at no cost           │
    │     │                    │   │        ▼ (AgentCore validates ~15-25s)     │
    │     │                    │   │   SendTaskSuccess ← tool complete_validation│
    │     │                    │   │ AgentCoreValidation (Pass, visual marker)  │
    │     │                    │   │ ValidateResult    (Lambda) processes verdict│
    │     └────────────────────┘   └─────────────────────────────────────────────┘
    ├─ shouldOrganize → OrganizeSolo  (Lambda · sleep 2s)
    ├─ shouldValidate → ValidateSolo  (Lambda · sleep 2s)
    └─ default → PipelineCompleted
   (errors) ─Catch─> PipelineFailed
```

- The agent runs in **asynchronous** mode (`@app.async_task`): the entrypoint
  returns right away and the ~15s of work happens in the background; when it
  finishes, the `complete_validation` tool calls `SendTaskSuccess(taskToken)`
  and **wakes up** Step Functions.
- The `ValidateDispatch` Lambda only forwards the token and dies — it **does not
  wait for the agent**.

**When to use:** long-running processes (up to 8h of agent time), multiple
agents in parallel, or when you want to decouple and pay nothing during the wait.

---

## Strategy B — direct call from Step Functions (synchronous)

Step Functions calls AgentCore **directly**, via SDK integration, with no Lambda
in the middle.

```
StartExecution
   │
   ▼ Step Functions: doc-pipeline-direct (STANDARD)
   Extract         Lambda · sleep 2s
   Identify        Lambda · sleep 2s · decides flags
   ValidateDirect  Task  →  arn:aws:states:::aws-sdk:bedrockagentcore:invokeAgentRuntime
                            (request-response: the SFN waits for the agent ~15-25s
                             and receives the verdict DIRECTLY in the step result)
   ParseAgentResponse  (Pass: Response string → JSON)
   ExtractVerdict      (Pass: exposes $.validation)
   PipelineCompleted
```

- The agent runs in **synchronous** mode (no `taskToken`): it validates and
  **returns the verdict in the payload itself**. The same runtime serves both
  modes — it decides based on the presence or absence of `taskToken` in the event.
- **No Lambda, zero glue code.** Simpler to read in the Graph view.

**When to use:** the agent responds quickly (the synchronous call has a ~15 min
limit), the pipeline is simple, and you accept paying for the *step* time while
the agent responds.

---

## Lambda vs Direct — comparison

| | A — Lambda + waitForTaskToken | B — Direct (SDK integration) |
|---|---|---|
| Lambda in the agent path | yes (dispatcher), but **dies early** | **none** |
| Agent mode | asynchronous (callback) | synchronous (response in payload) |
| Cost during processing | **zero** (SFN sleeping) | pays for the *step* time (Standard bills per transition, not per wait; the real cost is AgentCore) |
| Duration limit | up to 8h (agent) | ~15 min (synchronous call) |
| Complexity | higher (Lambda + IAM callback + token) | minimal (1 Task state) |
| Logic before/after the agent | explicit (`ValidateDispatch`/`ValidateResult`) | in the Pass states / other steps |

> **Summary:** for quick validations, **B (direct)** is simpler. For long-running
> or multi-agent processes, **A (Lambda + waitForTaskToken)** guarantees zero
> cost during the wait.

---

## How to prove the Lambda was NOT blocked (strategy A)

This is the central point of the demo.

### Quick way — `evidence-async.sh` (automated)

Generates the full evidence for one execution, cross-referencing the *state*
duration with the Lambda `Billed Duration` and the agent logs:

```bash
./evidence-async.sh                  # uses the latest execution of the pipeline (Lambda)
./evidence-async.sh <executionArn>   # a specific execution
```

Output (real example):

```
1) STEP FUNCTIONS — ValidateDispatch state (waitForTaskToken)
   TaskSubmitted (returned): 14:08:19   <- Lambda handed back control
   TaskSucceeded (callback): 14:08:34   <- AgentCore woke up the flow
   >> STATE DURATION        : 19.6s
   >> WAIT FOR THE AGENT    : 14.7s

2) LAMBDA — doc-pipeline-validate-dispatcher (CloudWatch REPORT)
   >> BILLED DURATION       : 4.8s   (time the Lambda ACTUALLY lived/was billed)

VERDICT
   State lasted ........ 19.6s
   Lambda billed ....... 4.8s
   Lambda idle avoided   14.9s (76%)
   ✅ PROVEN: the Lambda did NOT stay blocked waiting for AgentCore.

3) AGENTCORE RUNTIME — "ASYNCHRONOUS mode / background task" + "Waking up via SendTaskSuccess"
```

The logic: if the Lambda sat there waiting (the `await` anti-pattern), the
`Billed Duration` would be ~equal to the *state* duration. Since it was billed
for **4.8s** but the state lasted **19.6s**, it is proven that it died and the
agent processed the remaining ~15s with no Lambda alive. (For a strategy B
execution, the script warns that there is no Lambda to "sit idle".)

### Manual way — the same data in 3 places

### 1. Step Functions events (Event view / Table view)

In `ValidateDispatch`, the `waitForTaskToken` pattern generates **two separate
events**:

```
TaskStarted     ValidateDispatch   12:21:28   ← the Lambda started
TaskSubmitted   ValidateDispatch   12:21:33   ← the Lambda RETURNED and DIED (~5s)
        (~20s of wait: agent working, NO Lambda alive)
TaskSucceeded   ValidateDispatch   12:21:52   ← the agent woke up the flow (SendTaskSuccess)
```

- The presence of **`TaskSubmitted` separate from `TaskSucceeded`** is the
  **signature** of the async mode. In a synchronous invoke that event **does not
  exist** (it goes straight from `TaskStarted` to `TaskSucceeded`).
- The **gap between `TaskSubmitted` and `TaskSucceeded`** (~20s) is the time the
  agent ran with the Lambda **already terminated**.

### 2. Real Lambda duration (CloudWatch / REPORT log)

```bash
aws logs filter-log-events \
  --log-group-name /aws/lambda/doc-pipeline-validate-dispatcher \
  --filter-pattern "REPORT" --region us-east-1
```

The `Billed Duration` of `ValidateDispatch` is **a few seconds** (only the time
to fire the agent), **not** the ~15-25s of processing. Compare it with the
`ValidateDispatch` *state* time in Step Functions (much larger) — the difference
is the wait with no Lambda.

### 3. AgentCore runtime logs (the proof from the agent side)

```bash
aws logs filter-log-events \
  --log-group-name /aws/bedrock-agentcore/runtimes/<AGENT_ID>-DEFAULT \
  --region us-east-1
```

You will see, with timestamps that **match** Step Functions:
- `"Starting validation (ASYNCHRONOUS mode / background task)"` — right after the Lambda dies
- `"Waking up Step Functions via SendTaskSuccess"` — matches `TaskSucceeded` (#)

> **Rule of thumb for the presentation:** the `ValidateDispatch` *state* lasts
> ~20-25s, but the Lambda `Billed Duration` is ~5s. That difference, visible side
> by side, is the saving.

For **strategy B (direct)** there is no Lambda in the path, so the "blocked or
not" question does not even apply — what you pay for is the Step Functions
*step* time while AgentCore responds (visible in the `ValidateDirect` state
duration).

---

## Project structure

The Lambdas are **Node.js 22 (ESM)**; the AgentCore agent is **Python**.

```
template.yaml                       SAM: 2 state machines + Lambdas + IAM + X-Ray
statemachine/
  pipeline.asl.json                 strategy A (Lambda + waitForTaskToken)
  pipeline-direct.asl.json          strategy B (AgentCore direct, SDK integration)
functions/                          Lambdas in Node.js (index.mjs)
  extract/                          simulated OCR (sleep 2s + logs)
  identify/                         classifies the doc and decides flags (sleep 2s)
  validate_dispatcher/              "BEFORE" (strategy A): invokes AgentCore and returns immediately
                                    (@aws-sdk/client-bedrock-agentcore, bundled via esbuild)
  validate_result/                  "AFTER" (strategy A): processes the verdict
  organize/                         branch Organize / OrganizeSolo (sleep 2s)
  validate/                         ValidateSolo (sleep 2s, no agent)
agentcore/                          Agent in Python (dual-mode: async + synchronous)
  agent.py                          entrypoint + complete_validation tool
  Dockerfile  requirements.txt
events/                             test payloads
deploy.sh                           provisions everything (credentials + agent + SAM + callback)
destroy.sh                          removes everything (stack + AgentCore runtime)
run-demo.sh                         starts an execution and shows timeline + result + trace
evidence-async.sh                   proves the Lambda did not block (state x Billed Duration)
```

## Prerequisites

- AWS CLI, **AWS SAM CLI**, Docker, **Node.js 22** (Lambdas) and **Python 3.13** (agent)
- **Bedrock AgentCore Starter Toolkit**: `pip install bedrock-agentcore-starter-toolkit`
- Access to the model in Bedrock (e.g.: Claude Sonnet) enabled for the account/region
- Suggested region: `us-east-1`

## Automated deploy / teardown (recommended)

```bash
./deploy.sh          # checks credentials + tools, deploys agent + SAM, attaches callback and tests
./destroy.sh         # removes EVERYTHING (detaches policy, deletes stack, destroys the AgentCore runtime)
```

Useful flags:
- `./deploy.sh --skip-agent` — reuses the already-deployed agent (only updates the SAM stack)
- `./deploy.sh --no-test` — does not run the validation execution at the end
- `./destroy.sh --yes` — no confirmation prompt · `--keep-agent` — preserves the runtime

`deploy.sh` aborts early with a clear message if the **AWS credentials** are
missing/expired or if some tool is missing (aws, sam, docker, node, python3, agentcore).

## Deploy — step by step (manual)

> ⚠️ The commands below create resources in your AWS account. Run in a sandbox/dev account.

### 1. Deploy the agent to AgentCore (generates the runtime ARN)

```bash
cd agentcore
agentcore configure --entrypoint agent.py --name docpipeline
agentcore deploy            # container build, ECR push and runtime creation
# note the Agent Runtime ARN at the end of the output
cd ..
```

### 2. Deploy the two state machines (SAM), passing the agent ARN

```bash
sam build
sam deploy --guided \
  --parameter-overrides AgentRuntimeArn="arn:aws:bedrock-agentcore:us-east-1:ACCOUNT:runtime/docpipeline-XXXX"
```

Outputs:
- `StateMachineArn` — strategy A (Lambda + waitForTaskToken)
- `StateMachineDirectArn` — strategy B (AgentCore direct)
- `AgentCallbackPolicyArn` — **attach it to the AgentCore execution role** (needed
  only for strategy A, where the agent calls `SendTaskSuccess`).

### 3. Connect the callback (once — needed for strategy A)

```bash
aws iam attach-role-policy \
  --role-name <AGENTCORE_RUNTIME_ROLE> \
  --policy-arn <AgentCallbackPolicyArn-from-output>
```

## Run the demo

```bash
./run-demo.sh            # strategy A (Lambda + waitForTaskToken) — default
./run-demo.sh --direct   # strategy B (AgentCore direct, no Lambda)
./run-demo.sh --lambda   # same as A, explicit
```

The script starts the execution, follows it to the end and prints: the
**states timeline with durations**, the **agent verdict** (`source: agentcore`)
and the **X-Ray trace ID**.

## Observability

- **X-Ray**: enabled on the Lambdas (`Tracing: Active`) and on the state machines
  (`Tracing.Enabled`). In the **Service Map**/waterfall you can see the AgentCore
  node and the wait time.
- **Structured logs**: each Node.js Lambda emits JSON (`console.log`) with start/end and duration.
- **Step Functions logs**: `ALL` in `/aws/vendedlogs/states/doc-pipeline`
  and `/aws/vendedlogs/states/doc-pipeline-direct`.
- **AgentCore**: logs in `/aws/bedrock-agentcore/runtimes/*`.

> Note: the account has **X-Ray Transaction Search** enabled (destination
> CloudWatch Logs). Traces are stored in `aws/spans`; searching by trace ID
> depends on sampling (raised to 100% during the demo). See the waterfall in the
> **Spans** section of the trace page.

## Design notes

- **Why does strategy A use `lambda:invoke.waitForTaskToken` and not call
  AgentCore directly?** It is the way to get **zero cost during the wait** and to
  support long-running processes (up to 8h). Step Functions also has a direct
  integration (strategy B), but synchronous (~15 min) — that is why we keep both
  to compare.
- **`TimeoutSeconds`/`HeartbeatSeconds`** on `ValidateDispatch` prevent a stuck
  execution if the agent never calls the callback.
- **Dual-mode agent:** the same `agent.py` serves both state machines — with a
  `taskToken` it runs asynchronously (callback); without a `taskToken` it runs
  synchronously (verdict in the payload).
- **Demo routing:** the example document contains "CONTRACT/REGISTRATION/FINANCING",
  so Identify sets `shouldOrganize=true` AND `shouldValidate=true` and strategy A
  goes through `OrganizeAndValidateParallel` (Validate next to Organize).
