// Etapa Organize do pipeline. Simula 2s de trabalho + logs estruturados.

const SLEEP_SECONDS = Number(process.env.SIMULATED_WORK_SECONDS ?? "2");
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));

const log = (level, message, extra = {}) =>
  console.log(JSON.stringify({ level, message, service: "flow-credi-poc", ...extra }));

export const handler = async (event) => {
  log("INFO", "Organize iniciado", { event });

  await sleep(SLEEP_SECONDS);

  log("INFO", "Organize concluido", { duracao_s: SLEEP_SECONDS });
  return { ...event, organize: { status: "ORGANIZED", duracao_s: SLEEP_SECONDS } };
};
