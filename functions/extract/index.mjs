// Extract step of the pipeline.
// Simulates document extraction/OCR: sleeps ~2s and emits structured logs
// (JSON) for observability. In a real implementation, this is where the call
// to Amazon Textract would go. X-Ray stays enabled via "Tracing: Active" in the template.

const SLEEP_SECONDS = Number(process.env.SIMULATED_WORK_SECONDS ?? "2");
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));

const log = (level, message, extra = {}) =>
  console.log(JSON.stringify({ level, message, service: "doc-pipeline", ...extra }));

export const handler = async (event) => {
  log("INFO", "Event received", { event });

  const document = event.document ?? event;
  log("INFO", "Starting extraction/OCR", { document_key: document.key });

  await sleep(SLEEP_SECONDS);

  const extractedText =
    "PROPERTY REGISTRATION 12345 - REAL ESTATE FINANCING CONTRACT. " +
    "Document extracted via OCR (simulated).";

  log("INFO", "Extraction finished", {
    extracted_chars: extractedText.length,
    duration_s: SLEEP_SECONDS,
  });

  // Forward the original document + extraction result down the pipeline
  return {
    document,
    extract: { extractedText, pages: 1 },
  };
};
