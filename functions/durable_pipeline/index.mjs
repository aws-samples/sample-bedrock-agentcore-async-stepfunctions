// Pattern 3 — Lambda durable function (orchestration-as-code).
//
// This REPLACES Step Functions: the whole pipeline is expressed as ordinary
// code with the AWS Durable Execution SDK. Each stage becomes a `context.step`
// (checkpointed, with automatic retries), the Organize + Validate fan-out
// becomes `context.parallel`, and the wait for the agent becomes
// `context.waitForCallback` — the execution suspends with NO compute charge
// until the AgentCore agent resumes it via SendDurableExecutionCallbackSuccess.
//
// The agent is dispatched in ASYNC mode with a `callbackId` (instead of a Step
// Functions task token); the same agent.py handles both.

import { createHash } from "node:crypto";
import { withDurableExecution } from "@aws/durable-execution-sdk-js";
import {
  BedrockAgentCoreClient,
  InvokeAgentRuntimeCommand,
} from "@aws-sdk/client-bedrock-agentcore";

const AGENT_RUNTIME_ARN = process.env.AGENT_RUNTIME_ARN;
const WORK_S = Number(process.env.SIMULATED_WORK_SECONDS ?? "2");
const agentcore = new BedrockAgentCoreClient({});

const log = (level, message, extra = {}) =>
  console.log(JSON.stringify({ level, message, service: "doc-pipeline", ...extra }));
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));

// The callback result comes back as the JSON the agent sent; normalize it to
// an object whether the SDK hands us a parsed object or a JSON string.
function normalizeVerdict(v) {
  if (typeof v === "string") {
    try {
      return JSON.parse(v);
    } catch {
      return {};
    }
  }
  return v ?? {};
}

// Fires the AgentCore agent in ASYNC mode, passing the durable `callbackId`.
// The agent returns immediately ("accepted") and later resumes this execution.
async function dispatchAgentCore(callbackId, document, extractedText) {
  const payload = {
    prompt:
      "Validate the real estate financing document below according to the " +
      "bank's rules: check whether the property registration, the contract " +
      "and the data are complete and consistent. When finished, use the " +
      "callback tool to return the verdict.",
    document,
    extractedText,
    callbackId,
    executionId: callbackId,
  };
  // runtimeSessionId requires 33-128 chars. Deterministic hex hash (64) per callback.
  const sessionId = createHash("sha256").update(callbackId).digest("hex");
  log("INFO", "Dispatching AgentCore (async) with durable callbackId", { callbackId });
  await agentcore.send(
    new InvokeAgentRuntimeCommand({
      agentRuntimeArn: AGENT_RUNTIME_ARN,
      payload: new TextEncoder().encode(JSON.stringify(payload)),
      runtimeSessionId: sessionId,
    })
  );
}

const pipeline = async (event, context) => {
  const document = event.document ?? event;

  // 1. Extract (OCR) — durable step
  const extractedText = await context.step("extract", async () => {
    log("INFO", "Extract (durable step)", { document_key: document.key });
    await sleep(WORK_S);
    return (
      "PROPERTY REGISTRATION 12345 - REAL ESTATE FINANCING CONTRACT. " +
      "Document extracted via OCR (simulated)."
    );
  });

  // 2. Identify — durable step; decides the routing flags
  const identify = await context.step("identify", async () => {
    await sleep(WORK_S);
    const text = extractedText.toUpperCase();
    const isFinancing = ["CONTRACT", "REGISTRATION", "FINANCING"].some((t) =>
      text.includes(t)
    );
    const result = {
      type: document.type ?? "unknown",
      shouldOrganize: isFinancing,
      shouldValidate: isFinancing,
    };
    log("INFO", "Document classified (durable step)", result);
    return result;
  });

  // 3. Organize + Validate. The Validate branch is a waitForCallback that
  //    suspends (no compute cost) until the AgentCore agent calls back.
  let validation = null;
  const waitForAgent = (ctx) =>
    ctx.waitForCallback(
      "validate-agentcore",
      async (callbackId) => dispatchAgentCore(callbackId, document, extractedText),
      { timeout: { seconds: 120 } }
    );

  if (identify.shouldOrganize && identify.shouldValidate) {
    const results = await context.parallel(
      "organize-and-validate",
      [
        {
          name: "organize",
          func: async (ctx) =>
            ctx.step("organize", async () => {
              await sleep(WORK_S);
              return { status: "ORGANIZED" };
            }),
        },
        { name: "validate", func: waitForAgent },
      ],
      { maxConcurrency: 2 }
    );
    // Be tolerant of the return shape ({name: value} or {results: {name: value}}).
    const byName = results?.results ?? results ?? {};
    validation = normalizeVerdict(byName.validate);
  } else if (identify.shouldValidate) {
    validation = normalizeVerdict(await waitForAgent(context));
  }

  // 4. Result — durable step; processes the verdict returned by the agent
  const finalResult = await context.step("result", async () => {
    const approved = validation?.approved ?? false;
    const issues = validation?.issues ?? [];
    log("INFO", "Processing agent verdict (durable step)", { approved, num_issues: issues.length });
    await sleep(WORK_S);
    return {
      decision: approved ? "APPROVED" : "REJECTED",
      nextStep: approved ? "ARCHIVE_AND_NOTIFY_APPROVAL" : "RETURN_FOR_CORRECTION",
      totalIssues: issues.length,
    };
  });

  return { identify, validation, finalResult };
};

export const handler = withDurableExecution(pipeline);
