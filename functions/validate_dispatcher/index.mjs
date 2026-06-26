// Etapa Validate — DISPATCHER (coracao da PoC).
// Chamada pelo Step Functions com `lambda:invoke.waitForTaskToken` no branch
// Validate do Parallel. Recebe o taskToken, invoca o Bedrock AgentCore Runtime
// de forma ASSINCRONA repassando o token e RETORNA imediatamente — nao fica
// bloqueada esperando o agente. O branch fica DORMINDO (sem custo) ate o agente
// chamar SendTaskSuccess(taskToken).

import { createHash } from "node:crypto";
import {
  BedrockAgentCoreClient,
  InvokeAgentRuntimeCommand,
} from "@aws-sdk/client-bedrock-agentcore";

const AGENT_RUNTIME_ARN = process.env.AGENT_RUNTIME_ARN;
const agentcore = new BedrockAgentCoreClient({});

const log = (level, message, extra = {}) =>
  console.log(JSON.stringify({ level, message, service: "flow-credi-poc", ...extra }));

export const handler = async (event) => {
  log("INFO", "Validate dispatcher acionado", { event_keys: Object.keys(event) });

  const taskToken = event.taskToken;
  const document = event.document ?? {};
  const extractedText = event.extractedText ?? "";
  const executionId = event.executionId ?? "unknown";

  const payload = {
    prompt:
      "Valide o documento de financiamento imobiliario abaixo conforme as " +
      "regras do banco: verifique se a matricula, o contrato e os dados estao " +
      "completos e consistentes. Ao final, use a ferramenta de callback para " +
      "devolver o veredito ao Step Functions.",
    document,
    extractedText,
    taskToken,
    executionId,
  };

  // runtimeSessionId exige 33-128 chars. Hash hex (64) deterministico por execucao.
  const sessionId = createHash("sha256").update(executionId).digest("hex");

  log("INFO", "Disparando AgentCore (async) para validacao e liberando a Lambda", {
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
  log("INFO", "AgentCore aceitou a invocacao de validacao", { status });

  // Retorno imediato. NOTA: este retorno NAO conclui o passo waitForTaskToken —
  // o passo so termina quando o agente chamar SendTaskSuccess com o taskToken.
  log("INFO", "Dispatcher concluido, Lambda sera encerrada (sem espera)");
  return { dispatched: true, agentInvokeStatus: String(status) };
};
