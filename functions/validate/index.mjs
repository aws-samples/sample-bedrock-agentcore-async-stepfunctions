// "Light" Validate step (ValidateSolo / branch without agent). Simulates 2s + logs.

const SLEEP_SECONDS = Number(process.env.SIMULATED_WORK_SECONDS ?? "2");
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));

const log = (level, message, extra = {}) =>
  console.log(JSON.stringify({ level, message, service: "doc-pipeline", ...extra }));

export const handler = async (event) => {
  log("INFO", "Validate started", { event });

  await sleep(SLEEP_SECONDS);

  log("INFO", "Validate finished", { duration_s: SLEEP_SECONDS });
  return { ...event, validate: { status: "VALIDATED", duration_s: SLEEP_SECONDS } };
};
