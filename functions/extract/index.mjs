// Etapa Extract do pipeline.
// Simula a extracao/OCR de um documento: dorme ~2s e emite logs estruturados
// (JSON) para observabilidade. Numa implementacao real, aqui entraria a chamada
// ao Amazon Textract. X-Ray fica ativo via "Tracing: Active" no template.

const SLEEP_SECONDS = Number(process.env.SIMULATED_WORK_SECONDS ?? "2");
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));

const log = (level, message, extra = {}) =>
  console.log(JSON.stringify({ level, message, service: "flow-credi-poc", ...extra }));

export const handler = async (event) => {
  log("INFO", "Evento recebido", { event });

  const document = event.document ?? event;
  log("INFO", "Iniciando extracao/OCR", { document_key: document.key });

  await sleep(SLEEP_SECONDS);

  const extractedText =
    "MATRICULA 12345 - CONTRATO DE FINANCIAMENTO IMOBILIARIO. " +
    "Documento extraido via OCR (simulado).";

  log("INFO", "Extracao concluida", {
    chars_extraidos: extractedText.length,
    duracao_s: SLEEP_SECONDS,
  });

  // Propaga o documento original + resultado da extracao adiante no pipeline
  return {
    document,
    extract: { extractedText, pages: 1 },
  };
};
