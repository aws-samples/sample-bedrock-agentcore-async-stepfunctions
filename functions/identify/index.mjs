// Identify step of the pipeline (simple synchronous Lambda).
// Classifies the document type and decides the routing flags
// (shouldOrganize / shouldValidate). Does NOT call the agent. Simulates ~2s.

const SLEEP_SECONDS = Number(process.env.SIMULATED_WORK_SECONDS ?? "2");
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));

const log = (level, message, extra = {}) =>
  console.log(JSON.stringify({ level, message, service: "doc-pipeline", ...extra }));

function classify(document, extractedText) {
  const text = (extractedText ?? "").toUpperCase();

  // Demo rule: financing/contract documents need both organization
  // AND validation -> they take the Parallel path (Organize + Validate side by
  // side), where the Validate branch calls the agent (AgentCore).
  const isFinancing = ["CONTRACT", "REGISTRATION", "FINANCING"].some((t) =>
    text.includes(t)
  );

  const result = {
    type: document.type ?? "unknown",
    shouldOrganize: isFinancing,
    shouldValidate: isFinancing,
  };
  log("INFO", "Document classified", result);
  return result;
}

export const handler = async (event) => {
  log("INFO", "Identify started", { event });

  const document = event.document ?? {};
  const extractedText = event.extract?.extractedText ?? "";

  await sleep(SLEEP_SECONDS);
  const identify = classify(document, extractedText);

  log("INFO", "Identify finished", { duration_s: SLEEP_SECONDS });
  return { ...event, identify };
};
