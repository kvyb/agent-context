from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def load_payload() -> dict[str, Any]:
    raw = sys.stdin.read().strip()
    if not raw:
        raise ValueError("empty stdin payload")
    payload = json.loads(raw)
    if not isinstance(payload, dict):
        raise ValueError("payload must be an object")
    return payload


def normalize_string(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    text = value.strip()
    return text or None


def int_env(name: str, default: int, *, minimum: int | None = None, maximum: int | None = None) -> int:
    raw = os.getenv(name)
    try:
        value = int(raw) if raw is not None else default
    except Exception:
        value = default

    if minimum is not None:
        value = max(minimum, value)
    if maximum is not None:
        value = min(maximum, value)
    return value


def unique_strings(values: Any) -> list[str]:
    if not isinstance(values, list):
        return []

    output: list[str] = []
    seen: set[str] = set()
    for item in values:
        if isinstance(item, str):
            normalized = normalize_string(item)
        else:
            normalized = normalize_string(str(item))
        if not normalized:
            continue
        key = normalized.lower()
        if key in seen:
            continue
        seen.add(key)
        output.append(normalized)
    return output


def normalize_metadata_value(value: Any) -> Any:
    if value is None:
        return None
    if isinstance(value, str):
        return normalize_string(value)
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value
    if isinstance(value, list):
        normalized = unique_strings(value)
        return normalized or None
    return normalize_string(str(value))


def stringify_metadata_value(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, list):
        rendered = " | ".join(unique_strings(value))
        return rendered or None
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        return normalize_string(value)
    return normalize_string(str(value))


def parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    text = value.strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except Exception:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def unix_timestamp(value: datetime | None) -> int | None:
    if value is None:
        return None
    return int(value.timestamp())


def iso8601_utc(value: datetime | None) -> str | None:
    if value is None:
        return None
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def iso_day(value: datetime | None) -> str | None:
    if value is None:
        return None
    return value.astimezone(timezone.utc).strftime("%Y-%m-%d")


def build_mem0_config() -> dict[str, Any]:
    collection = os.getenv("AGENT_CONTEXT_MEM0_COLLECTION", "agent_context_memories")
    qdrant_path = os.getenv(
        "AGENT_CONTEXT_MEM0_QDRANT_PATH",
        str(Path.home() / ".agent-context" / "reports" / "mem0-qdrant"),
    )
    history_db_path = os.getenv(
        "AGENT_CONTEXT_MEM0_HISTORY_DB_PATH",
        str(Path.home() / ".agent-context" / "reports" / "mem0-history.sqlite"),
    )
    openrouter_base_url = os.getenv("AGENT_CONTEXT_OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1")
    llm_model = os.getenv(
        "AGENT_CONTEXT_MEM0_LLM_MODEL",
        "google/gemini-3-flash-preview",
    )
    embed_model = os.getenv("AGENT_CONTEXT_MEM0_EMBED_MODEL", "openai/text-embedding-3-small")
    rerank_model = os.getenv("AGENT_CONTEXT_MEM0_RERANK_MODEL", llm_model)
    rerank_top_k = int_env("AGENT_CONTEXT_MEM0_RERANK_TOP_K", 6, minimum=1, maximum=12)
    rerank_max_tokens = int_env("AGENT_CONTEXT_MEM0_RERANK_MAX_TOKENS", 16, minimum=4, maximum=64)
    api_key = (
        os.getenv("AGENT_CONTEXT_OPENROUTER_API_KEY")
        or os.getenv("OPENROUTER_API_KEY")
        or os.getenv("OPENAI_API_KEY")
    )

    Path(qdrant_path).mkdir(parents=True, exist_ok=True)
    Path(history_db_path).parent.mkdir(parents=True, exist_ok=True)

    config: dict[str, Any] = {
        "version": os.getenv("AGENT_CONTEXT_MEM0_VERSION", "v1.1"),
        "history_db_path": history_db_path,
        "vector_store": {
            "provider": "qdrant",
            "config": {
                "path": qdrant_path,
                "collection_name": collection,
                "on_disk": True,
            },
        },
        "llm": {
            "provider": "openai",
            "config": {
                "api_key": api_key,
                "model": llm_model,
                "openai_base_url": openrouter_base_url,
                "openrouter_base_url": openrouter_base_url,
            },
        },
        "embedder": {
            "provider": "openai",
            "config": {
                "api_key": api_key,
                "model": embed_model,
                "openai_base_url": openrouter_base_url,
            },
        },
    }

    if api_key:
        config["reranker"] = {
            "provider": "llm_reranker",
            "config": {
                "provider": "openai",
                "model": rerank_model,
                "api_key": api_key,
                "temperature": 0.0,
                "max_tokens": rerank_max_tokens,
                "top_k": rerank_top_k,
                "scoring_prompt": (
                    "Score how useful this memory is for answering an Agent Context query.\n"
                    "Prefer memories that directly match the same project, people, app, timeframe, "
                    "and concrete work details.\n"
                    "Penalize adjacent projects, vague summaries, reminders, and notes about analyzing "
                    "something later instead of the thing itself.\n"
                    "Return only a number from 0.0 to 1.0.\n\n"
                    "Query: {query}\n"
                    "Memory: {document}\n"
                    "Score:"
                ),
            },
        }

    return config


def build_memory_metadata(payload: dict[str, Any]) -> dict[str, Any]:
    metadata: dict[str, Any] = {}

    occurred_at_text = normalize_string(payload.get("occurredAt"))
    occurred_at = parse_iso(occurred_at_text)

    base_fields = {
        "scope": payload.get("scope"),
        "app_name": payload.get("appName"),
        "project": payload.get("project"),
        "agent_context_id": payload.get("id"),
    }
    for key, raw_value in base_fields.items():
        normalized = normalize_metadata_value(raw_value)
        if normalized is not None:
            metadata[key] = normalized

    entities = unique_strings(payload.get("entities"))
    if entities:
        metadata["entities"] = entities

    if occurred_at_text:
        metadata["occurred_at"] = occurred_at_text
    if occurred_at is not None:
        metadata["event_timestamp"] = unix_timestamp(occurred_at)
        metadata["event_day"] = iso_day(occurred_at)

    extra_metadata = payload.get("metadata")
    if isinstance(extra_metadata, dict):
        for raw_key, raw_value in extra_metadata.items():
            if not isinstance(raw_key, str):
                continue
            key = normalize_string(raw_key)
            if not key:
                continue
            normalized = normalize_metadata_value(raw_value)
            if normalized is None:
                continue
            metadata.setdefault(key, normalized)

    categories = derive_categories(payload, metadata)
    if categories:
        metadata["categories"] = categories

    return metadata


def derive_categories(payload: dict[str, Any], metadata: dict[str, Any]) -> list[str]:
    categories: list[str] = []
    seen: set[str] = set()

    def add(value: str | None) -> None:
        normalized = normalize_string(value)
        if not normalized:
            return
        key = normalized.lower()
        if key in seen:
            return
        seen.add(key)
        categories.append(normalized)

    add("work")
    add(stringify_metadata_value(metadata.get("scope")))

    status = stringify_metadata_value(metadata.get("status"))
    if status:
        add(status)
        if status == "blocked":
            add("blocker")

    combined_text = " ".join(
        value
        for value in [
            normalize_string(payload.get("summary")),
            stringify_metadata_value(metadata.get("app_name")),
            stringify_metadata_value(metadata.get("document")),
            stringify_metadata_value(metadata.get("url")),
        ]
        if value
    ).lower()

    if any(token in combined_text for token in ["meeting", "zoom", "call"]):
        add("meeting")
    if "interview" in combined_text:
        add("interview")
    if "transcript" in combined_text:
        add("transcript")

    return categories
