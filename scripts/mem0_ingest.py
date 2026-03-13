#!/usr/bin/env python3
"""Mem0 ingestion bridge for About Time.

Reads one JSON payload from stdin and writes one JSON response to stdout.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def load_payload() -> dict:
    raw = sys.stdin.read().strip()
    if not raw:
        raise ValueError("empty stdin payload")
    return json.loads(raw)


def build_mem0_config() -> dict:
    collection = os.getenv("AGENT_CONTEXT_MEM0_COLLECTION", "agent_context_memories")
    qdrant_path = os.getenv("AGENT_CONTEXT_MEM0_QDRANT_PATH", str(Path.home() / ".agent-context" / "reports" / "mem0-qdrant"))
    history_db_path = os.getenv(
        "AGENT_CONTEXT_MEM0_HISTORY_DB_PATH",
        str(Path.home() / ".agent-context" / "reports" / "mem0-history.sqlite"),
    )
    openrouter_base_url = os.getenv("AGENT_CONTEXT_OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1")
    llm_model = os.getenv("AGENT_CONTEXT_MEM0_LLM_MODEL", os.getenv("AGENT_CONTEXT_OPENROUTER_MODEL", "google/gemini-3.1-flash-lite-preview"))
    embed_model = os.getenv("AGENT_CONTEXT_MEM0_EMBED_MODEL", "openai/text-embedding-3-small")
    api_key = (
        os.getenv("AGENT_CONTEXT_OPENROUTER_API_KEY")
        or os.getenv("OPENROUTER_API_KEY")
        or os.getenv("OPENAI_API_KEY")
    )

    Path(qdrant_path).mkdir(parents=True, exist_ok=True)
    Path(history_db_path).parent.mkdir(parents=True, exist_ok=True)

    return {
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


def add_memory(memory, content: str, user_id: str, agent_id: str, metadata: dict):
    """Add memory with infer=True while avoiding thread-pool issues in mem0 local Qdrant mode."""
    filters = {}
    normalized_metadata = dict(metadata or {})
    if user_id:
        filters["user_id"] = user_id
        normalized_metadata.setdefault("user_id", user_id)
    if agent_id:
        filters["agent_id"] = agent_id
        normalized_metadata.setdefault("agent_id", agent_id)

    if hasattr(memory, "_add_to_vector_store"):
        try:
            messages = [{"role": "user", "content": content}]
            results = memory._add_to_vector_store(messages, normalized_metadata, filters, infer=True)
            return {"results": results, "mode": "single_thread_vector_store"}
        except Exception as exc:
            # Fall through to public API fallback below.
            last_error = exc
    else:
        last_error = None

    try:
        result = memory.add(
            content,
            user_id=user_id,
            agent_id=agent_id,
            infer=True,
            metadata=normalized_metadata,
        )
        return {"results": result, "mode": "public_add"}
    except TypeError:
        result = memory.add(
            content,
            user_id=user_id,
            infer=True,
            metadata=normalized_metadata,
        )
        return {"results": result, "mode": "public_add_no_agent"}
    except Exception:
        if last_error is not None:
            raise last_error
        raise


def main() -> int:
    payload = load_payload()
    user_id = os.getenv("AGENT_CONTEXT_MEM0_USER_ID", "agent-context-user")
    agent_id = os.getenv("AGENT_CONTEXT_MEM0_AGENT_ID", "agent-context-tracker")
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
    metadata = {
        "scope": payload.get("scope"),
        "app_name": payload.get("appName"),
        "project": payload.get("project"),
        "entities": payload.get("entities") or [],
        "metadata": payload.get("metadata") or {},
        "agent_context_id": payload.get("id"),
        "occurred_at": payload.get("occurredAt"),
    }

    try:
        result = add_memory(
            memory=memory,
            content=content,
            user_id=user_id,
            agent_id=agent_id,
            metadata=metadata,
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
