"""
vaathi.dev Sandbox API — Amazon Bedrock only (no public OpenAI).
Runs inside AWS: browser → Function URL → this Lambda → bedrock-runtime (EU).
"""
from __future__ import annotations

import json
import os
import time
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any

import boto3
from botocore.exceptions import ClientError

BEDROCK_REGION = os.environ.get("BEDROCK_REGION", "eu-west-1")
MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "eu.amazon.nova-micro-v1:0")
_origins_raw = os.environ.get(
    "ALLOWED_ORIGINS",
    "https://vaathi.dev|https://www.vaathi.dev|http://127.0.0.1:4321|http://localhost:4321",
)
ALLOWED_ORIGINS = {o.strip() for o in _origins_raw.replace(",", "|").split("|") if o.strip()}
DAILY_CAP_USD = Decimal(os.environ.get("DAILY_CAP_USD", "1.0"))
# Rough upper bound per request for ledger (Nova Micro is cheap; keep conservative).
EST_COST_PER_CALL_USD = Decimal(os.environ.get("EST_COST_PER_CALL_USD", "0.002"))
LEDGER_TABLE = os.environ.get("LEDGER_TABLE", "")
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "600"))
MAX_AGENT_STEPS = int(os.environ.get("MAX_AGENT_STEPS", "5"))

bedrock = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION)
dynamodb = boto3.resource("dynamodb", region_name=os.environ.get("AWS_REGION", "eu-west-2"))

FACTS = {
    "llm": "A Large Language Model predicts the next token in a sequence, trained on large text corpora.",
    "transformer": "Transformers use self-attention so every token can attend to every other token in the input.",
    "agent": "An agent is a goal-driven loop: plan, act (call tools), observe, repeat or stop.",
    "embedding": "An embedding turns text into a numeric vector so similar meanings sit close together.",
    "rag": "Retrieval-Augmented Generation retrieves relevant documents and feeds them to the model.",
    "mcp": "Model Context Protocol is a standard for connecting AI models to external tools and data sources.",
    "ai": "Artificial intelligence is the simulation of human intelligence by machines.",
    "prompt": "A prompt is the text you send to a model. Clarity beats cleverness.",
}

TOOL_CONFIG = {
    "tools": [
        {
            "toolSpec": {
                "name": "lookup_fact",
                "description": "Look up a short fact about an AI concept. Pass a short topic name.",
                "inputSchema": {
                    "json": {
                        "type": "object",
                        "properties": {
                            "topic": {"type": "string", "description": "AI topic word"},
                        },
                        "required": ["topic"],
                    }
                },
            }
        }
    ]
}


def _cors_headers(origin: str | None) -> dict[str, str]:
    allow = origin if origin in ALLOWED_ORIGINS else "https://vaathi.dev"
    return {
        "Access-Control-Allow-Origin": allow,
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "content-type",
        "Access-Control-Max-Age": "86400",
        "Content-Type": "application/json",
        "Vary": "Origin",
        "Cache-Control": "no-store",
    }


def _response(status: int, body: dict[str, Any], origin: str | None) -> dict[str, Any]:
    return {
        "statusCode": status,
        "headers": _cors_headers(origin),
        "body": json.dumps(body),
    }


def _parse_body(event: dict[str, Any]) -> dict[str, Any]:
    raw = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        import base64

        raw = base64.b64decode(raw).decode("utf-8")
    return json.loads(raw) if isinstance(raw, str) else raw


def _client_origin(event: dict[str, Any]) -> str | None:
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    return headers.get("origin")


def _origin_allowed(origin: str | None) -> bool:
    if not origin:
        return False
    return origin in ALLOWED_ORIGINS


def _today_key() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _check_and_charge_budget() -> tuple[bool, str]:
    """Site-wide soft ledger. AWS Budget is the hard backstop."""
    if not LEDGER_TABLE:
        return True, "ledger-disabled"
    table = dynamodb.Table(LEDGER_TABLE)
    day = _today_key()
    try:
        item = table.get_item(Key={"pk": f"day#{day}"}).get("Item") or {}
        spent = Decimal(str(item.get("spent_usd", "0")))
        if spent + EST_COST_PER_CALL_USD > DAILY_CAP_USD:
            return False, f"Daily sandbox budget reached (${DAILY_CAP_USD}). Try again tomorrow."
        table.update_item(
            Key={"pk": f"day#{day}"},
            UpdateExpression="ADD spent_usd :c, calls :one SET updated_at = :t",
            ExpressionAttributeValues={
                ":c": EST_COST_PER_CALL_USD,
                ":one": 1,
                ":t": int(time.time()),
            },
        )
        return True, "ok"
    except ClientError as exc:
        # Fail open to availability but log; Budget still caps AWS spend.
        print(json.dumps({"level": "error", "msg": "ledger", "error": str(exc)}))
        return True, "ledger-error"


def _lookup_fact(topic: str) -> str:
    key = (topic or "").lower().strip()
    for name, text in FACTS.items():
        if name in key:
            return text
    return f"No fact found for '{topic}'. Available: {', '.join(FACTS)}"


def _text_from_message(message: dict[str, Any]) -> str:
    parts = []
    for block in message.get("content") or []:
        if "text" in block:
            parts.append(block["text"])
    return "".join(parts).strip()


def _converse(system: str | None, messages: list[dict[str, Any]], tools: bool = False) -> dict[str, Any]:
    kwargs: dict[str, Any] = {
        "modelId": MODEL_ID,
        "messages": messages,
        "inferenceConfig": {"maxTokens": MAX_TOKENS, "temperature": 0},
    }
    if system:
        kwargs["system"] = [{"text": system}]
    if tools:
        kwargs["toolConfig"] = TOOL_CONFIG
    return bedrock.converse(**kwargs)


def run_chat(prompt: str, question: str) -> list[dict[str, str]]:
    steps = [
        {"type": "info", "label": "Simple chat (Bedrock)", "content": f"Model {MODEL_ID} via AWS — no public OpenAI."},
        {"type": "brief", "label": "Your prompt", "content": f"{prompt}\n\nQuestion: {question}"},
    ]
    resp = _converse(prompt, [{"role": "user", "content": [{"text": question}]}])
    answer = _text_from_message(resp["output"]["message"])
    steps.append({"type": "model", "label": "Model response", "content": answer})
    steps.append({"type": "answer", "label": "Done", "content": "One completion on Bedrock. No tools, no loop."})
    return steps


def run_rag(document: str, question: str) -> list[dict[str, str]]:
    steps = [
        {
            "type": "info",
            "label": "Document Q&A (Bedrock)",
            "content": "Document sent as context. Model answers from that text only.",
        },
        {
            "type": "brief",
            "label": "Document",
            "content": document[:300] + ("…" if len(document) > 300 else ""),
        },
        {"type": "brief", "label": "Question", "content": question},
    ]
    system = (
        "Answer the question using ONLY the document below. "
        "If the answer is not in the document, say so.\n\n"
        f"<document>\n{document}\n</document>"
    )
    resp = _converse(system, [{"role": "user", "content": [{"text": question}]}])
    answer = _text_from_message(resp["output"]["message"])
    steps.append({"type": "model", "label": "Model response", "content": answer})
    steps.append(
        {
            "type": "answer",
            "label": "Done",
            "content": "Grounded answer from document context on Bedrock.",
        }
    )
    return steps


def run_agent(question: str) -> list[dict[str, str]]:
    steps: list[dict[str, str]] = [
        {
            "type": "info",
            "label": "Agent + tools (Bedrock)",
            "content": f"Tool lookup_fact in a loop. Max {MAX_AGENT_STEPS} steps. All on AWS.",
        },
        {"type": "brief", "label": "Question", "content": question},
    ]
    system = (
        "You are a helpful assistant. Use the lookup_fact tool to find facts about AI concepts "
        "before answering. Look up each concept separately."
    )
    messages: list[dict[str, Any]] = [{"role": "user", "content": [{"text": question}]}]

    for step in range(MAX_AGENT_STEPS):
        resp = _converse(system, messages, tools=True)
        msg = resp["output"]["message"]
        messages.append(msg)
        text = _text_from_message(msg)
        tool_uses = [b["toolUse"] for b in (msg.get("content") or []) if "toolUse" in b]

        if not tool_uses:
            steps.append(
                {
                    "type": "model",
                    "label": f"Step {step + 1} — Model",
                    "content": text or "(finished)",
                }
            )
            steps.append({"type": "answer", "label": "Final answer", "content": text or "Done."})
            return steps

        steps.append(
            {
                "type": "model",
                "label": f"Step {step + 1} — Model thinking",
                "content": text or "→ calling tools",
            }
        )
        tool_results = []
        for tu in tool_uses:
            name = tu["name"]
            tid = tu["toolUseId"]
            args = tu.get("input") or {}
            steps.append({"type": "tool", "label": f"Tool call: {name}", "content": json.dumps(args)})
            if name == "lookup_fact":
                result = _lookup_fact(str(args.get("topic", "")))
            else:
                result = f"Unknown tool: {name}"
            steps.append({"type": "result", "label": "Tool result", "content": result})
            tool_results.append(
                {"toolResult": {"toolUseId": tid, "content": [{"text": result}]}}
            )
        messages.append({"role": "user", "content": tool_results})

    steps.append({"type": "answer", "label": "Stopped", "content": f"Step limit ({MAX_AGENT_STEPS}) reached."})
    return steps


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    origin = _client_origin(event)
    method = (event.get("requestContext") or {}).get("http", {}).get("method") or event.get("httpMethod") or "POST"

    if method == "OPTIONS":
        return {"statusCode": 204, "headers": _cors_headers(origin), "body": ""}

    if method != "POST":
        return _response(405, {"error": "Method not allowed"}, origin)

    if not _origin_allowed(origin):
        return _response(403, {"error": "Origin not allowed"}, origin)

    ok, reason = _check_and_charge_budget()
    if not ok:
        return _response(429, {"error": reason}, origin)

    try:
        body = _parse_body(event)
    except json.JSONDecodeError:
        return _response(400, {"error": "Invalid JSON"}, origin)

    scenario = (body.get("scenario") or "chat").strip()
    try:
        if scenario == "chat":
            steps = run_chat(
                (body.get("prompt") or "You are a helpful assistant that explains AI concepts in one short paragraph.").strip(),
                (body.get("question") or "What is a large language model?").strip(),
            )
        elif scenario == "rag":
            steps = run_rag(
                (body.get("document") or "").strip(),
                (body.get("question") or "What is the role of the model inside an agent?").strip(),
            )
        elif scenario == "agent":
            steps = run_agent(
                (body.get("question") or "What is an agent and how does it relate to an LLM?").strip(),
            )
        else:
            return _response(400, {"error": f"Unknown scenario: {scenario}"}, origin)
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "ClientError")
        msg = exc.response.get("Error", {}).get("Message", str(exc))
        print(json.dumps({"level": "error", "code": code, "message": msg}))
        return _response(502, {"error": f"Bedrock {code}: {msg[:240]}"}, origin)
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"level": "error", "message": str(exc)}))
        return _response(500, {"error": "Sandbox failed"}, origin)

    return _response(
        200,
        {
            "provider": "bedrock",
            "model": MODEL_ID,
            "region": BEDROCK_REGION,
            "scenario": scenario,
            "steps": steps,
        },
        origin,
    )
