// Etapa Validate "leve" (ValidateSolo / branch sem agente). Simula 2s + logs.

const SLEEP_SECONDS = Number(process.env.SIMULATED_WORK_SECONDS ?? "2");
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));

const log = (level, message, extra = {}) =>
  console.log(JSON.stringify({ level, message, service: "flow-credi-poc", ...extra }));

export const handler = async (event) => {
  log("INFO", "Validate iniciado", { event });

  await sleep(SLEEP_SECONDS);

  log("INFO", "Validate concluido", { duracao_s: SLEEP_SECONDS });
  return { ...event, validate: { status: "VALIDATED", duracao_s: SLEEP_SECONDS } };
};
