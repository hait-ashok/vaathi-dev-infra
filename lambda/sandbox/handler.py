"""
vaathi.dev Sandbox API — Amazon Bedrock only (no public OpenAI).
Browser → Function URL → this Lambda → bedrock-runtime (EU).

Also: access-request / admin approve + Cognito PreSignUp allowlist gate.
"""
from __future__ import annotations

import json
import os
import re
import time
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any

import boto3
from botocore.exceptions import ClientError

BEDROCK_REGION = os.environ.get("BEDROCK_REGION", "eu-west-1")
MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "eu.amazon.nova-micro-v1:0")
COGNITO_REGION = os.environ.get("COGNITO_REGION", os.environ.get("AWS_REGION", "eu-west-2"))
COGNITO_USER_POOL_ID = os.environ.get("COGNITO_USER_POOL_ID", "")
ADMIN_GROUP = os.environ.get("ADMIN_GROUP", "sandbox-admin")
REQUIRE_AUTH = os.environ.get("REQUIRE_AUTH", "true").lower() in ("1", "true", "yes")
_origins_raw = os.environ.get(
    "ALLOWED_ORIGINS",
    "https://vaathi.dev|https://www.vaathi.dev|http://127.0.0.1:4321|http://localhost:4321",
)
ALLOWED_ORIGINS = {o.strip() for o in _origins_raw.replace(",", "|").split("|") if o.strip()}
DAILY_CAP_USD = Decimal(os.environ.get("DAILY_CAP_USD", "1.0"))
EST_COST_PER_CALL_USD = Decimal(os.environ.get("EST_COST_PER_CALL_USD", "0.002"))
LEDGER_TABLE = os.environ.get("LEDGER_TABLE", "")
ACCESS_TABLE = os.environ.get("ACCESS_TABLE", "")
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "600"))
MAX_AGENT_STEPS = int(os.environ.get("MAX_AGENT_STEPS", "5"))

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

bedrock = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION)
cognito = boto3.client("cognito-idp", region_name=COGNITO_REGION)
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


def _response_headers() -> dict[str, str]:
    # Do NOT set Access-Control-* here. Function URL Cors config already adds them.
    return {
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
    }


def _response(status: int, body: dict[str, Any], origin: str | None = None) -> dict[str, Any]:
    return {
        "statusCode": status,
        "headers": _response_headers(),
        "body": json.dumps(body),
    }


def _parse_body(event: dict[str, Any]) -> dict[str, Any]:
    raw = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        import base64

        raw = base64.b64decode(raw).decode("utf-8")
    return json.loads(raw) if isinstance(raw, str) else (raw or {})


def _client_origin(event: dict[str, Any]) -> str | None:
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    return headers.get("origin")


def _origin_allowed(origin: str | None) -> bool:
    if not origin:
        return False
    return origin in ALLOWED_ORIGINS


def _norm_email(email: str) -> str:
    return (email or "").strip().lower()


def _valid_email(email: str) -> bool:
    return bool(email) and len(email) <= 254 and EMAIL_RE.match(email) is not None


def _today_key() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _access_table():
    if not ACCESS_TABLE:
        return None
    return dynamodb.Table(ACCESS_TABLE)


def _access_status(email: str) -> str | None:
    table = _access_table()
    if table is None:
        return None
    try:
        item = table.get_item(Key={"email": email}).get("Item") or {}
        return (item.get("status") or "").strip() or None
    except ClientError as exc:
        print(json.dumps({"level": "error", "msg": "access_get", "error": str(exc)}))
        return None


def _is_approved(email: str) -> bool:
    return _access_status(email) == "approved"


def _check_and_charge_budget() -> tuple[bool, str]:
    """Site-wide soft ledger ($1/day). AWS Budget on Bedrock is the hard backstop."""
    if not LEDGER_TABLE:
        return False, "Ledger not configured"
    table = dynamodb.Table(LEDGER_TABLE)
    day = _today_key()
    try:
        item = table.get_item(Key={"pk": f"day#{day}"}).get("Item") or {}
        spent = Decimal(str(item.get("spent_usd", "0")))
        if spent + EST_COST_PER_CALL_USD > DAILY_CAP_USD:
            return False, f"Daily Bedrock budget reached (${DAILY_CAP_USD}). Try again tomorrow."
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
        print(json.dumps({"level": "error", "msg": "ledger", "error": str(exc)}))
        return False, "Budget ledger unavailable"


def _bearer_token(event: dict[str, Any]) -> str | None:
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    auth = headers.get("authorization") or ""
    if auth.lower().startswith("bearer "):
        return auth[7:].strip() or None
    return None


def _attrs_map(user: dict[str, Any]) -> dict[str, str]:
    out: dict[str, str] = {}
    for attr in user.get("UserAttributes") or []:
        name = attr.get("Name")
        if name:
            out[name] = attr.get("Value") or ""
    return out


def _verify_cognito_user(token: str) -> tuple[bool, str, str, bool]:
    """
    Validate access token with Cognito GetUser.
    Returns (ok, username_or_error, email, is_admin).
    """
    if not token:
        return False, "Sign in required", "", False
    try:
        user = cognito.get_user(AccessToken=token)
        username = user.get("Username") or "user"
        attrs = _attrs_map(user)
        email = _norm_email(attrs.get("email") or username)
        is_admin = False
        if COGNITO_USER_POOL_ID and username:
            try:
                groups = cognito.admin_list_groups_for_user(
                    UserPoolId=COGNITO_USER_POOL_ID,
                    Username=username,
                )
                names = {g.get("GroupName") for g in (groups.get("Groups") or [])}
                is_admin = ADMIN_GROUP in names
            except ClientError as exc:
                print(json.dumps({"level": "warn", "msg": "list_groups", "error": str(exc)}))
        return True, username, email, is_admin
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "NotAuthorized")
        print(json.dumps({"level": "warn", "auth": code}))
        return False, "Session expired or invalid — sign in again", "", False


def _raw_path(event: dict[str, Any]) -> str:
    path = (
        event.get("rawPath")
        or (event.get("requestContext") or {}).get("http", {}).get("path")
        or event.get("path")
        or "/"
    )
    return path.rstrip("/") or "/"


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


def _handle_access_request(event: dict[str, Any], origin: str | None) -> dict[str, Any]:
    table = _access_table()
    if table is None:
        return _response(503, {"error": "Access table not configured"}, origin)
    try:
        body = _parse_body(event)
    except json.JSONDecodeError:
        return _response(400, {"error": "Invalid JSON"}, origin)
    email = _norm_email(str(body.get("email") or ""))
    if not _valid_email(email):
        return _response(400, {"error": "Valid email required"}, origin)

    existing = table.get_item(Key={"email": email}).get("Item") or {}
    status = (existing.get("status") or "").strip()
    now = int(time.time())
    if status == "approved":
        return _response(
            200,
            {
                "ok": True,
                "status": "approved",
                "message": "This email is already approved. Create an account or sign in.",
            },
            origin,
        )
    if status == "pending":
        return _response(
            200,
            {
                "ok": True,
                "status": "pending",
                "message": "Access request already pending. We will review it soon.",
            },
            origin,
        )

    table.put_item(
        Item={
            "email": email,
            "status": "pending",
            "requestedAt": now,
            "updatedAt": now,
        }
    )
    return _response(
        200,
        {
            "ok": True,
            "status": "pending",
            "message": "Request submitted. You will be able to register after approval.",
        },
        origin,
    )


def _handle_list_access(origin: str | None, admin_email: str) -> dict[str, Any]:
    table = _access_table()
    if table is None:
        return _response(503, {"error": "Access table not configured"}, origin)
    try:
        resp = table.scan(Limit=200)
        items = resp.get("Items") or []
        while "LastEvaluatedKey" in resp and len(items) < 500:
            resp = table.scan(ExclusiveStartKey=resp["LastEvaluatedKey"], Limit=200)
            items.extend(resp.get("Items") or [])
    except ClientError as exc:
        print(json.dumps({"level": "error", "msg": "access_scan", "error": str(exc)}))
        return _response(502, {"error": "Could not list requests"}, origin)

    def sort_key(it: dict[str, Any]) -> int:
        return int(it.get("requestedAt") or it.get("updatedAt") or 0)

    pending = sorted(
        [i for i in items if (i.get("status") or "") == "pending"],
        key=sort_key,
        reverse=True,
    )
    recent = sorted(
        [i for i in items if (i.get("status") or "") in ("approved", "denied")],
        key=lambda i: int(i.get("decidedAt") or i.get("updatedAt") or 0),
        reverse=True,
    )[:50]

    def public_item(i: dict[str, Any]) -> dict[str, Any]:
        return {
            "email": i.get("email"),
            "status": i.get("status"),
            "requestedAt": i.get("requestedAt"),
            "decidedAt": i.get("decidedAt"),
            "decidedBy": i.get("decidedBy"),
        }

    return _response(
        200,
        {
            "admin": admin_email,
            "pending": [public_item(i) for i in pending],
            "recent": [public_item(i) for i in recent],
        },
        origin,
    )


def _handle_access_decide(
    event: dict[str, Any], origin: str | None, admin_email: str
) -> dict[str, Any]:
    table = _access_table()
    if table is None:
        return _response(503, {"error": "Access table not configured"}, origin)
    try:
        body = _parse_body(event)
    except json.JSONDecodeError:
        return _response(400, {"error": "Invalid JSON"}, origin)
    email = _norm_email(str(body.get("email") or ""))
    decision = (body.get("decision") or "").strip().lower()
    if not _valid_email(email):
        return _response(400, {"error": "Valid email required"}, origin)
    if decision not in ("approve", "deny"):
        return _response(400, {"error": "decision must be approve or deny"}, origin)
    status = "approved" if decision == "approve" else "denied"
    now = int(time.time())
    try:
        table.update_item(
            Key={"email": email},
            UpdateExpression=(
                "SET #s = :s, decidedAt = :t, decidedBy = :who, updatedAt = :t, "
                "requestedAt = if_not_exists(requestedAt, :t)"
            ),
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={
                ":s": status,
                ":t": now,
                ":who": admin_email,
            },
        )
    except ClientError as exc:
        print(json.dumps({"level": "error", "msg": "access_decide", "error": str(exc)}))
        return _response(502, {"error": "Could not update access"}, origin)
    return _response(200, {"ok": True, "email": email, "status": status}, origin)


def _run_sandbox(event: dict[str, Any], origin: str | None, who: str) -> dict[str, Any]:
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
                (
                    body.get("prompt")
                    or "You are a helpful assistant that explains AI concepts in one short paragraph."
                ).strip(),
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
            "user": who,
            "dailyCapUsd": str(DAILY_CAP_USD),
            "steps": steps,
        },
        origin,
    )


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    origin = _client_origin(event)
    method = (
        (event.get("requestContext") or {}).get("http", {}).get("method")
        or event.get("httpMethod")
        or "POST"
    ).upper()
    path = _raw_path(event)

    if method == "OPTIONS":
        return {"statusCode": 204, "headers": _response_headers(), "body": ""}

    if not _origin_allowed(origin):
        return _response(403, {"error": "Origin not allowed"}, origin)

    # Public: request access (no Cognito yet)
    if method == "POST" and path in ("/access-request", "/access-request/"):
        return _handle_access_request(event, origin)

    # Admin routes
    if path in ("/access-requests", "/access-requests/"):
        token = _bearer_token(event)
        ok_auth, who_or_err, email, is_admin = _verify_cognito_user(token or "")
        if not ok_auth:
            return _response(401, {"error": who_or_err}, origin)
        if not is_admin:
            return _response(403, {"error": "Admin access required"}, origin)
        if method == "GET":
            return _handle_list_access(origin, email)
        return _response(405, {"error": "Method not allowed"}, origin)

    if method == "POST" and path in ("/access-decide", "/access-decide/"):
        token = _bearer_token(event)
        ok_auth, who_or_err, email, is_admin = _verify_cognito_user(token or "")
        if not ok_auth:
            return _response(401, {"error": who_or_err}, origin)
        if not is_admin:
            return _response(403, {"error": "Admin access required"}, origin)
        return _handle_access_decide(event, origin, email)

    # Default: Bedrock Run (POST /)
    if method != "POST":
        return _response(405, {"error": "Method not allowed"}, origin)

    if REQUIRE_AUTH:
        token = _bearer_token(event)
        ok_auth, who_or_err, email, _is_admin = _verify_cognito_user(token or "")
        if not ok_auth:
            return _response(401, {"error": who_or_err}, origin)
        if ACCESS_TABLE and not _is_approved(email):
            return _response(
                403,
                {"error": "Sandbox access not approved for this email. Request access first."},
                origin,
            )
        who = email or who_or_err
    else:
        who = "anonymous"

    return _run_sandbox(event, origin, who)


def presignup(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """
    Cognito PreSignUp trigger — only approved emails may register.
    Fail closed if ACCESS_TABLE is missing or status is not approved.
    """
    attrs = event.get("request", {}).get("userAttributes") or {}
    email = _norm_email(attrs.get("email") or event.get("userName") or "")
    if not _valid_email(email):
        raise Exception("A valid email is required to register.")
    if not ACCESS_TABLE:
        raise Exception("Access control is not configured. Registration is closed.")
    status = _access_status(email)
    if status != "approved":
        raise Exception(
            "This email is not approved for Sandbox. Submit an access request on vaathi.dev/sandbox first."
        )
    # Auto-confirm email attribute verification is still via ConfirmSignUp code;
    # do not autoConfirm unless we want to skip email verify.
    return event
