// Etapa "depois do agente" — processa o veredito devolvido pelo AgentCore.
// Roda DEPOIS que o branch Validate acordou (callback do agente). Representa a
// logica de negocio que consome o resultado da validacao. Simula ~2s.

const SLEEP_SECONDS = Number(process.env.SIMULATED_WORK_SECONDS ?? "2");
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));

const log = (level, message, extra = {}) =>
  console.log(JSON.stringify({ level, message, service: "flow-credi-poc", ...extra }));

export const handler = async (event) => {
  log("INFO", "ValidateResult iniciado (pos-agente)", { event_keys: Object.keys(event) });

  // O veredito do agente chega em $.validation (output do SendTaskSuccess)
  const validation = event.validation ?? {};
  const aprovado = validation.aprovado;
  const problemas = validation.problemas ?? [];

  log("INFO", "Processando veredito do agente", {
    aprovado,
    num_problemas: problemas.length,
  });

  await sleep(SLEEP_SECONDS);

  const resultadoFinal = {
    decisao: aprovado ? "APROVADO" : "REPROVADO",
    proximoPasso: aprovado ? "ARQUIVAR_E_NOTIFICAR_APROVACAO" : "DEVOLVER_PARA_CORRECAO",
    totalProblemas: problemas.length,
  };
  log("INFO", "ValidateResult concluido", { resultadoFinal, duracao_s: SLEEP_SECONDS });

  return { ...event, resultadoFinal };
};
