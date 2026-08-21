# Document Pipeline with Bedrock AgentCore

> This code accompanies the AWS blog post
> [Asynchronous patterns for calling Amazon Bedrock AgentCore agents in serverless pipelines](https://aws.amazon.com/blogs/machine-learning/asynchronous-patterns-for-calling-amazon-bedrock-agentcore-agents-in-serverless-pipelines/).

> **Goal of the demo:** validate real estate financing documents with a
> **Bedrock AgentCore** agent (~15s of processing) inside a **Step Functions**
> pipeline, showing how to **not waste Lambda cost** while the agent works.

Demonstrates, with infrastructure as code (AWS SAM), **three strategies** for
integrating a Bedrock AgentCore agent into a serverless pipeline without keeping
a Lambda blocked during the agent's processing — two orchestrated with Step
Functions and one with a Lambda durable function.

The project deploys **three orchestrations** that do the same thing via
different paths, so you can compare them side by side:

| Strategy | Orchestrator | How it calls AgentCore |
|---|---|---|
| **A — with Lambda** | Step Functions `doc-pipeline` | Lambda dispatcher + `lambda:invoke.waitForTaskToken` (asynchronous) |
| **B — direct** | Step Functions `doc-pipeline-direct` | `aws-sdk:bedrockagentcore:invokeAgentRuntime` — **no Lambda** (synchronous) |
| **C — durable function** | Lambda `doc-pipeline-durable` | `context.waitForCallback` + `SendDurableExecutionCallbackSuccess` (asynchronous, orchestration-as-code) |

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
    │     │                    │   │   SendTaskSuccess ← tool conclude_validation│
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
  finishes, the `conclude_validation` tool calls `SendTaskSuccess(taskToken)`
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
   ParseVerdict        (Pass: Response string → JSON verdict)
   PipelineCompleted
```

- The agent runs in **synchronous** mode (no `taskToken`, no `callbackId`): it
  validates and **returns the verdict in the payload itself**. The same runtime
  serves all modes — it decides based on which fields are present in the event.
- **No Lambda, zero glue code.** Simpler to read in the Graph view.

**When to use:** the agent responds quickly (the synchronous call has a ~15 min
limit), the pipeline is simple, and you accept paying for the *step* time while
the agent responds.

---

## Strategy C — Lambda durable function (asynchronous, orchestration-as-code)

Instead of a state machine, the whole pipeline is expressed as ordinary code in
a single Lambda **durable function** (AWS Durable Execution SDK). Stages become
`context.step`, the Organize + Validate fan-out becomes `context.parallel`, and
the wait for the agent becomes `context.waitForCallback` — the execution
suspends with **no compute charge** until the agent resumes it.

```
aws lambda invoke (async, qualified) : doc-pipeline-durable
   │
   ▼ Lambda durable function (@aws/durable-execution-sdk-js)
   context.step("extract")     OCR (simulated 2s)
   context.step("identify")    decides flags
   context.parallel("organize-and-validate")
     ├─ context.step("organize")
     └─ context.waitForCallback("validate-agentcore", dispatchAgentCore, {timeout:120s})
            → invokes AgentCore (async) passing a durable callbackId
            → the execution SLEEPS at no cost (no Lambda running)
                 ▼ (AgentCore validates ~15-25s)
            SendDurableExecutionCallbackSuccess ← tool conclude_validation
   context.step("result")      processes the verdict
```

- The agent runs **asynchronously**: the entrypoint returns "accepted" and,
  when finished, the `conclude_validation` tool calls
  `SendDurableExecutionCallbackSuccess(CallbackId, Result)` to **resume** the
  durable execution.
- **No Step Functions, no glue Lambdas** — orchestration and business logic live
  together as code. Durable functions must be invoked through a **qualified
  identifier** (version/alias) — the stack publishes a `live` alias.

**When to use:** you prefer expressing orchestration as code in one place
instead of a state machine, want zero cost during the wait, and are comfortable
with orchestration living inside Lambda (up to 1 year of durable execution).

---

## Comparison

| | A — Lambda + waitForTaskToken | B — Direct (SDK integration) | C — Durable function |
|---|---|---|---|
| Orchestrator | Step Functions | Step Functions | Lambda (code) |
| Lambda in the agent path | yes (dispatcher), but **dies early** | **none** | the durable function itself (**suspended**, no charge) |
| Agent mode | asynchronous (task token) | synchronous (response in payload) | asynchronous (durable callback) |
| Cost during processing | **zero** (SFN sleeping) | pays for the *step* time (real cost is AgentCore) | **zero** (execution suspended) |
| Duration limit | up to 8h (agent) | ~15 min (synchronous call) | up to 1 year (durable execution) |
| Complexity | higher (Lambda + IAM callback + token) | minimal (1 Task state) | medium (orchestration-as-code + callback IAM) |
| Logic before/after the agent | explicit (`ValidateDispatch`/`ValidateResult`) | in the Pass states / other steps | plain `context.step` calls |

> **Summary:** for quick validations, **B (direct)** is simpler. For long-running
> or multi-agent processes, **A (waitForTaskToken)** and **C (durable function)**
> both guarantee zero cost during the wait — choose A/B if you want Step
> Functions orchestration, or C if you prefer orchestration-as-code in Lambda.

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

Output (from a real run):

```
====================================================================
1) STEP FUNCTIONS — ValidateDispatch state (waitForTaskToken)
====================================================================
  Entered state           : 09:41:22.170
  TaskStarted (Lambda)    : 09:41:22.234
  TaskSubmitted (returned): 09:41:27.721   <- Lambda handed back control
  TaskSucceeded (callback): 09:41:40.807   <- AgentCore woke up the flow
  Exited state            : 09:41:40.820
  >> STATE DURATION        :   18.6s  (Step Functions waiting)
  >> WAIT FOR THE AGENT    :   13.1s  (between TaskSubmitted and TaskSucceeded)
====================================================================
2) LAMBDA — doc-pipeline-validate-dispatcher (CloudWatch REPORT)
====================================================================
  Duration         :    4.9s
  >> BILLED DURATION:    5.2s  (time the Lambda ACTUALLY lived/was billed)
====================================================================
VERDICT
====================================================================
  State lasted .............   18.6s
  Lambda billed ............    5.2s
  Lambda IDLE time avoided .   13.4s  (72% of the time)
  ✅ PROVEN: the Lambda did NOT stay blocked waiting for AgentCore.
     It lived 5.2s and died; the agent processed the other
     ~13s with NO Lambda alive (Step Functions sleeping).
     In the anti-pattern (await), the Lambda would be billed for the whole ~19s.
3) AGENTCORE RUNTIME — proof from the agent side (async start + callback)
====================================================================
  INFO:doc-pipeline-agent:Starting validation (ASYNCHRONOUS mode / background task)
  INFO:doc-pipeline-agent:Waking up Step Functions via SendTaskSuccess: {'approved': False, ...}
```

The logic: if the Lambda sat there waiting (the `await` anti-pattern), the
`Billed Duration` would be ~equal to the *state* duration. Since it was billed
for **5.2s** but the state lasted **18.6s**, it is proven that it died and the
agent processed the remaining ~13s with no Lambda alive. (For a strategy B
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
template.yaml                       SAM: 2 state machines + durable function + Lambdas + IAM + X-Ray
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
  durable_pipeline/                 strategy C: the whole pipeline as a durable function
                                    (@aws/durable-execution-sdk-js, bundled via esbuild)
agentcore/                          Agent in Python (tri-mode: task token / durable callback / synchronous)
  agent.py                          entrypoint + conclude_validation tool
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
- A **recent `boto3`/`botocore`** in the environment that runs `agentcore`
  (`pip install -U boto3 botocore`) — older versions do not know the
  `bedrock-agentcore-control` service and `agentcore deploy` fails to create the runtime.
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

### 2. Deploy the pipelines (SAM), passing the agent ARN

```bash
sam build
sam deploy --guided \
  --parameter-overrides AgentRuntimeArn="arn:aws:bedrock-agentcore:us-east-1:ACCOUNT:runtime/docpipeline-XXXX"
```

Outputs:
- `StateMachineArn` — strategy A (Lambda + waitForTaskToken)
- `StateMachineDirectArn` — strategy B (AgentCore direct)
- `DurablePipelineFunctionName` / `DurablePipelineAliasArn` — strategy C (durable function)
- `AgentCallbackPolicyArn` — **attach it to the AgentCore execution role** (needed
  for strategy A, where the agent calls `SendTaskSuccess`, and strategy C, where
  it calls `SendDurableExecutionCallbackSuccess`).

### 3. Connect the callback (once — needed for strategies A and C)

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
./run-demo.sh --durable  # strategy C (Lambda durable function, no Step Functions)
```

For strategies A and B the script starts the execution, follows it to the end
and prints: the **states timeline with durations**, the **agent verdict**
(`source: agentcore`) and the **X-Ray trace ID**.

For strategy C (`--durable`) it invokes the durable function asynchronously
(qualified `live` alias) and prints where to watch it — durable functions run
in Lambda, not Step Functions, so there is no execution graph. Follow the
CloudWatch logs (`/aws/lambda/doc-pipeline-durable`), the Lambda console's
**Durable executions** tab, or list them by version (the API rejects an alias):

```bash
VER=$(aws lambda get-alias --function-name doc-pipeline-durable --name live --query FunctionVersion --output text)
aws lambda list-durable-executions-by-function --function-name doc-pipeline-durable:$VER
```

## Observability

- **X-Ray**: enabled on the Lambdas (`Tracing: Active`) and on the state machines
  (`Tracing.Enabled`). In the **Service Map**/waterfall you can see the AgentCore
  node and the wait time.
- **Structured logs**: each Node.js Lambda emits JSON (`console.log`) with start/end and duration.
- **Step Functions logs**: `ALL` in `/aws/vendedlogs/states/doc-pipeline`
  and `/aws/vendedlogs/states/doc-pipeline-direct`.
- **Durable function logs**: `/aws/lambda/doc-pipeline-durable` (step/checkpoint
  progress for strategy C).
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
- **`TimeoutSeconds`/`HeartbeatSeconds`** on `ValidateDispatch` (and the
  `waitForCallback` `timeout` in strategy C) prevent a stuck execution if the
  agent never calls back.
- **Tri-mode agent:** the same `agent.py` serves all three orchestrations — with
  a `taskToken` it runs asynchronously and calls `SendTaskSuccess`; with a
  `callbackId` it runs asynchronously and calls
  `SendDurableExecutionCallbackSuccess`; with neither it runs synchronously and
  returns the verdict in the payload.
- **Durable function IAM (strategy C):** the durable function's execution role
  needs `lambda:CheckpointDurableExecution`/`GetDurableExecutionState`, and the
  AgentCore role needs `lambda:SendDurableExecutionCallback*` (added to the same
  `AgentCallbackPolicy` alongside the Step Functions callback permissions).
- **Enabling durability (strategy C):** the `DurableConfig` property on the
  function is what turns on durable execution. It is **create-only** — you cannot
  add it to an existing function (CloudFormation reports the custom-named resource
  needs replacing), so changing it requires recreating the function. The function
  is also invoked through a qualified `live` alias (`AutoPublishAlias`), since
  durable functions require a qualified identifier.
- **Demo routing:** the example document contains "CONTRACT/REGISTRATION/FINANCING",
  so Identify sets `shouldOrganize=true` AND `shouldValidate=true` and strategy A
  goes through `OrganizeAndValidateParallel` (Validate next to Organize).
