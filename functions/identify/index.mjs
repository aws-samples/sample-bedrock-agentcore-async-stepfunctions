// Etapa Identify do pipeline (Lambda sincrona simples).
// Classifica o tipo do documento e decide as flags de roteamento
// (shouldOrganize / shouldValidate). NAO chama o agente. Simula ~2s.

const SLEEP_SECONDS = Number(process.env.SIMULATED_WORK_SECONDS ?? "2");
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));

const log = (level, message, extra = {}) =>
  console.log(JSON.stringify({ level, message, service: "flow-credi-poc", ...extra }));

function classificar(document, extractedText) {
  const texto = (extractedText ?? "").toUpperCase();

  // Regra de demo: documentos de financiamento/contrato precisam de organizacao
  // E validacao -> entram no caminho Parallel (Organize + Validate lado a lado),
  // onde o branch Validate chama o agente (AgentCore).
  const ehFinanciamento = ["CONTRATO", "MATRICULA", "FINANCIAMENTO"].some((t) =>
    texto.includes(t)
  );

  const result = {
    tipo: document.tipo ?? "desconhecido",
    shouldOrganize: ehFinanciamento,
    shouldValidate: ehFinanciamento,
  };
  log("INFO", "Documento classificado", result);
  return result;
}

export const handler = async (event) => {
  log("INFO", "Identify iniciado", { event });

  const document = event.document ?? {};
  const extractedText = event.extract?.extractedText ?? "";

  await sleep(SLEEP_SECONDS);
  const identify = classificar(document, extractedText);

  log("INFO", "Identify concluido", { duracao_s: SLEEP_SECONDS });
  return { ...event, identify };
};
