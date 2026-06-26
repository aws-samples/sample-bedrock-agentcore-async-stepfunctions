"""Agente do Bedrock AgentCore — etapa Validate do pipeline.

Suporta DOIS modos de invocacao:

  A) ASSINCRONO (com taskToken) — usado pela state machine `flow-credi-document-
     pipeline`, via Lambda dispatcher + `lambda:invoke.waitForTaskToken`.
     O entrypoint dispara o trabalho em background (`@app.async_task`), retorna
     "accepted" na hora e, ao terminar (~15s), chama `SendTaskSuccess(taskToken)`.

  B) SINCRONO (sem taskToken) — usado pela state machine
     `flow-credi-pipeline-direct`, que chama o Runtime DIRETO via SDK integration
     (`states:::aws-sdk:bedrockagentcore:invokeAgentRuntime`), SEM Lambda.
     Aqui o entrypoint roda a validacao e RETORNA o veredito no proprio payload.

Observabilidade: o AgentCore Runtime exporta traces para X-Ray/CloudWatch quando
a execution role tem permissao. Logs em /aws/bedrock-agentcore/runtimes/*.
"""

import asyncio
import json
import logging
import os
import time

import boto3
from bedrock_agentcore import BedrockAgentCoreApp
from strands import Agent, tool

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
logger = logging.getLogger("flow-credi-agent")

app = BedrockAgentCoreApp()
sfn = boto3.client("stepfunctions")

MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "us.anthropic.claude-sonnet-4-6")

# Guarda o veredito produzido pela tool durante a invocacao corrente.
_current = {"taskToken": None, "executionId": None, "veredito": None}


@tool
def concluir_validacao(aprovado: bool, problemas: list, resumo: str) -> str:
    """Registra o veredito da validacao do documento.

    Use esta ferramenta UMA vez, ao final da validacao, para concluir a etapa.
    No modo assincrono ela tambem acorda o Step Functions (SendTaskSuccess); no
    modo sincrono o veredito e devolvido no payload de resposta.

    Args:
        aprovado: True se o documento passou na validacao do banco.
        problemas: Lista de problemas/inconsistencias encontrados (vazia se ok).
        resumo: Resumo curto do resultado da validacao.
    """
    veredito = {
        "aprovado": aprovado,
        "problemas": problemas,
        "resumo": resumo,
        "source": "agentcore",
    }
    _current["veredito"] = veredito

    task_token = _current["taskToken"]
    if task_token:
        logger.info("Acordando Step Functions via SendTaskSuccess: %s", veredito)
        sfn.send_task_success(taskToken=task_token, output=json.dumps(veredito))
        return "Step Functions acordado com sucesso."

    logger.info("Veredito registrado (modo sincrono): %s", veredito)
    return "Veredito registrado."


def _build_agent() -> Agent:
    return Agent(
        model=MODEL_ID,
        tools=[concluir_validacao],
        system_prompt=(
            "Voce e um analista de validacao de documentos de financiamento "
            "imobiliario de um banco. Verifique se o documento esta completo e "
            "consistente (matricula, contrato, dados das partes, valores). "
            "Pense com calma e, ao concluir, OBRIGATORIAMENTE chame a ferramenta "
            "'concluir_validacao' com o veredito (aprovado, problemas, resumo)."
        ),
    )


def _mensagem(prompt: str, document: dict, extracted_text: str) -> str:
    return (
        f"{prompt}\n\nDocumento: {json.dumps(document, ensure_ascii=False)}\n"
        f"Texto extraido:\n{extracted_text}"
    )


@app.async_task
async def validar_documento_async(prompt: str, document: dict, extracted_text: str):
    """Modo A — trabalho de fundo: valida (~15s) e a tool chama o callback."""
    inicio = time.time()
    logger.info("Iniciando validacao (modo ASSINCRONO / background task)")
    agent = _build_agent()
    try:
        await agent.invoke_async(_mensagem(prompt, document, extracted_text))
        decorrido = time.time() - inicio
        if decorrido < 15:
            await asyncio.sleep(15 - decorrido)
        logger.info("Validacao assincrona concluida em %.1fs", time.time() - inicio)
    except Exception as exc:  # noqa: BLE001 — falha vira SendTaskFailure
        logger.exception("Falha na validacao; sinalizando SendTaskFailure")
        if _current["taskToken"]:
            sfn.send_task_failure(
                taskToken=_current["taskToken"],
                error="AgentValidationError",
                cause=str(exc),
            )


@app.entrypoint
async def handler(event):
    """Decide o modo pela presenca de taskToken."""
    logger.info("Invocacao recebida pelo AgentCore")

    _current["taskToken"] = event.get("taskToken")
    _current["executionId"] = event.get("executionId")
    _current["veredito"] = None
    prompt = event.get("prompt", "Valide o documento.")
    document = event.get("document", {})
    extracted_text = event.get("extractedText", "")

    # ----- Modo A: ASSINCRONO (com taskToken) -----
    if _current["taskToken"]:
        asyncio.create_task(validar_documento_async(prompt, document, extracted_text))
        return {"status": "accepted", "message": "Validacao iniciada em background."}

    # ----- Modo B: SINCRONO (sem taskToken) — chamada direta do Step Functions -----
    inicio = time.time()
    logger.info("Iniciando validacao (modo SINCRONO / chamada direta do SFN)")
    agent = _build_agent()
    await agent.invoke_async(_mensagem(prompt, document, extracted_text))
    veredito = _current["veredito"] or {
        "aprovado": False,
        "problemas": ["Agente nao chamou concluir_validacao"],
        "resumo": "Veredito ausente.",
        "source": "agentcore",
    }
    logger.info("Validacao sincrona concluida em %.1fs", time.time() - inicio)
    # Retorna o veredito no proprio payload — o SFN recebe direto no output do step.
    return {"validation": veredito}


if __name__ == "__main__":
    app.run()
