// Validate step — DISPATCHER (the heart of the sample).
// Called by Step Functions with `lambda:invoke.waitForTaskToken` in the
// Validate branch of the Parallel. Receives the taskToken, invokes the Bedrock
// AgentCore Runtime ASYNCHRONOUSLY forwarding the token, and RETURNS
// immediately — it does not stay blocked waiting for the agent. The branch
// SLEEPS (at no cost) until the agent calls SendTaskSuccess(taskToken).

import { createHash } from "node:crypto";
import {
  BedrockAgentCoreClient,
  InvokeAgentRuntimeCommand,
} from "@aws-sdk/client-bedrock-agentcore";

const AGENT_RUNTIME_ARN = process.env.AGENT_RUNTIME_ARN;
const agentcore = new BedrockAgentCoreClient({});

const log = (level, message, extra = {}) =>
  console.log(JSON.stringify({ level, message, service: "doc-pipeline", ...extra }));

export const handler = async (event) => {
  log("INFO", "Validate dispatcher triggered", { event_keys: Object.keys(event) });

  const taskToken = event.taskToken;
  const document = event.document ?? {};
  const extractedText = event.extractedText ?? "";
  const executionId = event.executionId ?? "unknown";

  const payload = {
    prompt:
      "Validate the real estate financing document below according to the " +
      "bank's rules: check whether the property registration, the contract " +
      "and the data are complete and consistent. When finished, use the " +
      "callback tool to return the verdict to Step Functions.",
    document,
    extractedText,
    taskToken,
    executionId,
  };

  // runtimeSessionId requires 33-128 chars. Deterministic hex hash (64) per execution.
  const sessionId = createHash("sha256").update(executionId).digest("hex");

  log("INFO", "Dispatching AgentCore (async) for validation and releasing the Lambda", {
    runtime_arn: AGENT_RUNTIME_ARN,
    execution_id: executionId,
  });

  const response = await agentcore.send(
    new InvokeAgentRuntimeCommand({
      agentRuntimeArn: AGENT_RUNTIME_ARN,
      payload: new TextEncoder().encode(JSON.stringify(payload)),
      runtimeSessionId: sessionId,
    })
  );

  const status = response.statusCode ?? "n/a";
  log("INFO", "AgentCore accepted the validation invocation", { status });

  // Immediate return. NOTE: this return does NOT complete the waitForTaskToken step —
  // the step only finishes when the agent calls SendTaskSuccess with the taskToken.
  log("INFO", "Dispatcher finished, Lambda will terminate (no waiting)");
  return { dispatched: true, agentInvokeStatus: String(status) };
};
