// "After the agent" step — processes the verdict returned by AgentCore.
// Runs AFTER the Validate branch woke up (agent callback). Represents the
// business logic that consumes the validation result. Simulates ~2s.

const SLEEP_SECONDS = Number(process.env.SIMULATED_WORK_SECONDS ?? "2");
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));

const log = (level, message, extra = {}) =>
  console.log(JSON.stringify({ level, message, service: "doc-pipeline", ...extra }));

export const handler = async (event) => {
  log("INFO", "ValidateResult started (post-agent)", { event_keys: Object.keys(event) });

  // The agent verdict arrives in $.validation (output of SendTaskSuccess)
  const validation = event.validation ?? {};
  const approved = validation.approved;
  const issues = validation.issues ?? [];

  log("INFO", "Processing agent verdict", {
    approved,
    num_issues: issues.length,
  });

  await sleep(SLEEP_SECONDS);

  const finalResult = {
    decision: approved ? "APPROVED" : "REJECTED",
    nextStep: approved ? "ARCHIVE_AND_NOTIFY_APPROVAL" : "RETURN_FOR_CORRECTION",
    totalIssues: issues.length,
  };
  log("INFO", "ValidateResult finished", { finalResult, duration_s: SLEEP_SECONDS });

  return { ...event, finalResult };
};
