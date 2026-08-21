"""Bedrock AgentCore agent — Validate step of the pipeline.

Supports THREE invocation modes; the same runtime serves all of them and
decides based on which fields are present in the event:

  A) ASYNCHRONOUS via Step Functions task token (`taskToken`) — used by the
     `doc-pipeline` state machine, via a Lambda dispatcher +
     `lambda:invoke.waitForTaskToken`. The entrypoint kicks off the work in the
     background (`@app.async_task`), returns "accepted" immediately and, once it
     finishes (~15s), calls `SendTaskSuccess(taskToken)`.

  B) SYNCHRONOUS (no `taskToken`, no `callbackId`) — used by the
     `doc-pipeline-direct` state machine, which invokes the Runtime DIRECTLY via
     SDK integration (`states:::aws-sdk:bedrockagentcore:invokeAgentRuntime`),
     with NO Lambda. Here the entrypoint runs the validation and RETURNS the
     verdict in the response payload itself.

  C) ASYNCHRONOUS via Lambda durable function callback (`callbackId`) — used by
     the `doc-pipeline-durable` Lambda durable function (orchestration-as-code
     with the AWS Durable Execution SDK). The entrypoint returns "accepted"
     immediately and, once finished, resumes the durable execution via
     `SendDurableExecutionCallbackSuccess(CallbackId, Result)`.

Observability: the AgentCore Runtime exports traces to X-Ray/CloudWatch when
the execution role has permission. Logs in /aws/bedrock-agentcore/runtimes/*.
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
logger = logging.getLogger("doc-pipeline-agent")

app = BedrockAgentCoreApp()
sfn = boto3.client("stepfunctions")
lambda_client = boto3.client("lambda")

MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "us.anthropic.claude-sonnet-4-6")

# Holds the verdict and the callback handles for the current invocation.
_current = {"taskToken": None, "callbackId": None, "executionId": None, "verdict": None}


@tool
def conclude_validation(approved: bool, issues: list, summary: str) -> str:
    """Record the document validation verdict.

    Use this tool ONCE, at the end of the validation, to conclude the step.
    Depending on how the agent was invoked, it also resumes the caller:
    with a Step Functions task token it calls SendTaskSuccess; with a durable
    function callback id it calls SendDurableExecutionCallbackSuccess; in sync
    mode the verdict is returned in the response payload.

    Args:
        approved: True if the document passed the bank's validation.
        issues: List of problems/inconsistencies found (empty if OK).
        summary: Short summary of the validation result.
    """
    verdict = {
        "approved": approved,
        "issues": issues,
        "summary": summary,
        "source": "agentcore",
    }
    _current["verdict"] = verdict

    task_token = _current["taskToken"]
    if task_token:
        logger.info("Waking up Step Functions via SendTaskSuccess: %s", verdict)
        sfn.send_task_success(taskToken=task_token, output=json.dumps(verdict))
        return "Step Functions woken up successfully."

    callback_id = _current["callbackId"]
    if callback_id:
        logger.info("Resuming durable function via SendDurableExecutionCallbackSuccess: %s", verdict)
        lambda_client.send_durable_execution_callback_success(
            CallbackId=callback_id,
            Result=json.dumps(verdict).encode("utf-8"),
        )
        return "Durable function resumed successfully."

    logger.info("Verdict recorded (sync mode): %s", verdict)
    return "Verdict recorded."


def _build_agent() -> Agent:
    return Agent(
        model=MODEL_ID,
        tools=[conclude_validation],
        system_prompt=(
            "You are a document validation analyst for a bank's real estate "
            "financing process. Check whether the document is complete and "
            "consistent (property registration, contract, party details, "
            "amounts). Think it through and, once finished, you MUST call the "
            "'conclude_validation' tool with the verdict (approved, issues, "
            "summary)."
        ),
    )


def _message(prompt: str, document: dict, extracted_text: str) -> str:
    return (
        f"{prompt}\n\nDocument: {json.dumps(document, ensure_ascii=False)}\n"
        f"Extracted text:\n{extracted_text}"
    )


@app.async_task
async def validate_document_async(prompt: str, document: dict, extracted_text: str):
    """Modes A and C — background work: validates (~15s) and the tool calls the callback."""
    start = time.time()
    logger.info("Starting validation (ASYNCHRONOUS mode / background task)")
    agent = _build_agent()
    try:
        await agent.invoke_async(_message(prompt, document, extracted_text))
        elapsed = time.time() - start
        if elapsed < 15:
            await asyncio.sleep(15 - elapsed)
        logger.info("Async validation finished in %.1fs", time.time() - start)
    except Exception as exc:  # noqa: BLE001 — failure becomes a callback failure
        logger.exception("Validation failed; signaling failure to the caller")
        if _current["taskToken"]:
            sfn.send_task_failure(
                taskToken=_current["taskToken"],
                error="AgentValidationError",
                cause=str(exc),
            )
        elif _current["callbackId"]:
            # Best-effort failure signal; if it does not go through, the durable
            # function's waitForCallback timeout (120s) still unblocks the flow.
            try:
                lambda_client.send_durable_execution_callback_failure(
                    CallbackId=_current["callbackId"],
                    ErrorMessage=str(exc),
                )
            except Exception:  # noqa: BLE001
                logger.exception("Could not send durable callback failure")


@app.entrypoint
async def handler(event):
    """Decide the mode based on the presence of taskToken / callbackId."""
    logger.info("Invocation received by AgentCore")

    _current["taskToken"] = event.get("taskToken")
    _current["callbackId"] = event.get("callbackId")
    _current["executionId"] = event.get("executionId")
    _current["verdict"] = None
    prompt = event.get("prompt", "Validate the document.")
    document = event.get("document", {})
    extracted_text = event.get("extractedText", "")

    # ----- Modes A and C: ASYNCHRONOUS (task token or durable callback id) -----
    if _current["taskToken"] or _current["callbackId"]:
        asyncio.create_task(validate_document_async(prompt, document, extracted_text))
        return {"status": "accepted", "message": "Validation started in background."}

    # ----- Mode B: SYNCHRONOUS (no token, no callback) — direct call from Step Functions -----
    start = time.time()
    logger.info("Starting validation (SYNCHRONOUS mode / direct call from SFN)")
    agent = _build_agent()
    await agent.invoke_async(_message(prompt, document, extracted_text))
    verdict = _current["verdict"] or {
        "approved": False,
        "issues": ["Agent did not call conclude_validation"],
        "summary": "Verdict missing.",
        "source": "agentcore",
    }
    logger.info("Sync validation finished in %.1fs", time.time() - start)
    # Return the verdict in the payload itself — the SFN receives it directly in the step output.
    return {"validation": verdict}


if __name__ == "__main__":
    app.run()
