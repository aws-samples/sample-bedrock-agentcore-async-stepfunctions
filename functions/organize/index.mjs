// Organize step of the pipeline. Simulates 2s of work + structured logs.

const SLEEP_SECONDS = Number(process.env.SIMULATED_WORK_SECONDS ?? "2");
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));

const log = (level, message, extra = {}) =>
  console.log(JSON.stringify({ level, message, service: "doc-pipeline", ...extra }));

export const handler = async (event) => {
  log("INFO", "Organize started", { event });

  await sleep(SLEEP_SECONDS);

  log("INFO", "Organize finished", { duration_s: SLEEP_SECONDS });
  return { ...event, organize: { status: "ORGANIZED", duration_s: SLEEP_SECONDS } };
};
