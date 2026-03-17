#!/usr/bin/env python3
"""Mem0 ingestion bridge for About Time."""

from __future__ import annotations

import json
import inspect
import os

from mem0_common import (
    build_mem0_config,
    build_memory_metadata,
    load_payload,
    normalize_string,
    parse_iso,
    unix_timestamp,
)


def add_memory(memory, content: str, user_id: str, agent_id: str, metadata: dict, timestamp: int | None):
    """Add a memory using the public API first, then a private local fallback if needed."""
    normalized_metadata = dict(metadata or {})
    if user_id:
        normalized_metadata.setdefault("user_id", user_id)
    if agent_id:
        normalized_metadata.setdefault("agent_id", agent_id)

    attempts: list[dict] = []
    if user_id and agent_id:
        attempts.append({"user_id": user_id, "agent_id": agent_id})
    if user_id:
        attempts.append({"user_id": user_id})
    if agent_id:
        attempts.append({"agent_id": agent_id})
    if not attempts:
        attempts.append({})

    add_parameters = set(inspect.signature(memory.add).parameters.keys())
    supports_timestamp = "timestamp" in add_parameters

    last_error = None
    for scope_kwargs in attempts:
        kwargs = {
            **scope_kwargs,
            "infer": True,
            "metadata": normalized_metadata,
        }
        if supports_timestamp and timestamp is not None:
            kwargs["timestamp"] = timestamp
        try:
            result = memory.add(content, **kwargs)
            return {"results": result, "mode": "public_add"}
        except TypeError as exc:
            last_error = exc
            continue
        except Exception as exc:
            last_error = exc

    if hasattr(memory, "_add_to_vector_store"):
        filters = {}
        if user_id:
            filters["user_id"] = user_id
        if agent_id:
            filters["agent_id"] = agent_id

        try:
            messages = [{"role": "user", "content": content}]
            results = memory._add_to_vector_store(messages, normalized_metadata, filters, infer=True)
            return {"results": results, "mode": "single_thread_vector_store"}
        except Exception as exc:
            last_error = exc

    if last_error is not None:
        raise last_error
    raise RuntimeError("mem0 add failed without an error")


def main() -> int:
    payload = load_payload()
    user_id = normalize_string(os.getenv("AGENT_CONTEXT_MEM0_USER_ID")) or "agent-context-user"
    agent_id = normalize_string(os.getenv("AGENT_CONTEXT_MEM0_AGENT_ID")) or "agent-context-tracker"
    openrouter_key = (
        os.getenv("AGENT_CONTEXT_OPENROUTER_API_KEY")
        or os.getenv("OPENROUTER_API_KEY")
        or os.getenv("OPENAI_API_KEY")
    )

    if not openrouter_key:
        print(json.dumps({"status": "error", "error": "missing OpenRouter/OpenAI key for Mem0"}))
        return 1

    try:
        from mem0 import Memory
    except Exception as exc:
        print(json.dumps({"status": "error", "error": f"mem0 import failed: {exc}"}))
        return 1

    config = build_mem0_config()

    try:
        memory = Memory.from_config(config)
    except Exception as first_error:
        try:
            memory = Memory()
        except Exception as second_error:
            print(
                json.dumps(
                    {
                        "status": "error",
                        "error": f"mem0 init failed: {first_error}; fallback failed: {second_error}",
                    }
                )
            )
            return 1

    content = payload.get("summary", "")
    if not isinstance(content, str):
        content = str(content)
    metadata = build_memory_metadata(payload)
    occurred_at = parse_iso(payload.get("occurredAt") if isinstance(payload.get("occurredAt"), str) else None)
    timestamp = unix_timestamp(occurred_at)

    try:
        result = add_memory(
            memory=memory,
            content=content,
            user_id=user_id,
            agent_id=agent_id,
            metadata=metadata,
            timestamp=timestamp,
        )
    except Exception as exc:
        print(json.dumps({"status": "error", "error": f"mem0 add failed: {exc}"}))
        return 1

    print(json.dumps({"status": "ok", "result": result}, default=str))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(json.dumps({"status": "error", "error": str(exc)}))
        raise
