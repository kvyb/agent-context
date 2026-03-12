#!/usr/bin/env python3
"""Mem0 semantic search bridge for About Time.

Reads one JSON payload from stdin:
{
  "query": "...",
  "start": "ISO8601 or empty",
  "end": "ISO8601 or empty",
  "limit": 20
}

Outputs:
{
  "status": "ok",
  "hits": [...]
}
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


def load_input() -> dict[str, Any]:
    raw = sys.stdin.read().strip()
    if not raw:
        raise ValueError("empty stdin payload")
    payload = json.loads(raw)
    if not isinstance(payload, dict):
        raise ValueError("payload must be an object")
    return payload


def parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    text = value.strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(text)
    except Exception:
        return None


def build_mem0_config() -> dict[str, Any]:
    collection = os.getenv("ABOUT_TIME_MEM0_COLLECTION", "about_time_memories")
    qdrant_path = os.getenv("ABOUT_TIME_MEM0_QDRANT_PATH", str(Path.home() / ".about-time" / "reports" / "mem0-qdrant"))
    history_db_path = os.getenv(
        "ABOUT_TIME_MEM0_HISTORY_DB_PATH",
        str(Path.home() / ".about-time" / "reports" / "mem0-history.sqlite"),
    )
    openrouter_base_url = os.getenv("ABOUT_TIME_OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1")
    llm_model = os.getenv("ABOUT_TIME_MEM0_LLM_MODEL", os.getenv("ABOUT_TIME_OPENROUTER_MODEL", "google/gemini-3.1-flash-lite-preview"))
    embed_model = os.getenv("ABOUT_TIME_MEM0_EMBED_MODEL", "openai/text-embedding-3-small")
    api_key = (
        os.getenv("ABOUT_TIME_OPENROUTER_API_KEY")
        or os.getenv("OPENROUTER_API_KEY")
        or os.getenv("OPENAI_API_KEY")
    )

    Path(qdrant_path).mkdir(parents=True, exist_ok=True)
    Path(history_db_path).parent.mkdir(parents=True, exist_ok=True)

    return {
        "version": os.getenv("ABOUT_TIME_MEM0_VERSION", "v1.1"),
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


def call_search(memory, query: str, user_id: str, agent_id: str, limit: int) -> list[dict[str, Any]]:
    attempts = [
        lambda: memory.search(
            query=query,
            user_id=user_id,
            agent_id=agent_id,
            limit=limit,
            keyword_search=True,
            rerank=True,
        ),
        lambda: memory.search(
            query=query,
            user_id=user_id,
            limit=limit,
            keyword_search=True,
            rerank=True,
        ),
        lambda: memory.search(
            query=query,
            user_id=user_id,
            agent_id=agent_id,
            limit=limit,
            keyword_search=True,
        ),
        lambda: memory.search(
            query=query,
            user_id=user_id,
            limit=limit,
            keyword_search=True,
        ),
        lambda: memory.search(query, user_id=user_id, agent_id=agent_id, limit=limit),
        lambda: memory.search(query=query, user_id=user_id, agent_id=agent_id, limit=limit),
        lambda: memory.search(query, user_id=user_id, limit=limit),
        lambda: memory.search(query=query, user_id=user_id, limit=limit),
        lambda: memory.search(query, limit=limit),
        lambda: memory.search(query=query, limit=limit),
    ]

    last_error = None
    for attempt in attempts:
        try:
            raw = attempt()
            if isinstance(raw, list):
                return [row for row in raw if isinstance(row, dict)]
            if isinstance(raw, dict):
                results = raw.get("results")
                if isinstance(results, list):
                    return [row for row in results if isinstance(row, dict)]
            return []
        except Exception as exc:  # noqa: PERF203
            last_error = exc

    if last_error:
        raise last_error
    return []


def normalize_hit(raw: dict[str, Any]) -> dict[str, Any]:
    metadata = raw.get("metadata") if isinstance(raw.get("metadata"), dict) else {}
    memory_text = raw.get("memory") or raw.get("text") or raw.get("content") or ""
    if not isinstance(memory_text, str):
        memory_text = str(memory_text)

    app_name = raw.get("app_name") or metadata.get("app_name")
    project = raw.get("project") or metadata.get("project")
    occurred_at = raw.get("occurred_at") or metadata.get("occurred_at")

    return {
        "id": raw.get("id"),
        "score": raw.get("score"),
        "memory": memory_text.strip(),
        "app_name": app_name if isinstance(app_name, str) else None,
        "project": project if isinstance(project, str) else None,
        "occurred_at": occurred_at if isinstance(occurred_at, str) else None,
        "metadata": {k: str(v) for k, v in metadata.items()},
    }


def filter_hits_by_time(hits: list[dict[str, Any]], start: datetime | None, end: datetime | None) -> list[dict[str, Any]]:
    if not start and not end:
        return hits

    filtered: list[dict[str, Any]] = []
    for hit in hits:
        occurred_raw = hit.get("occurred_at")
        occurred = parse_iso(occurred_raw if isinstance(occurred_raw, str) else None)
        if occurred is None:
            filtered.append(hit)
            continue

        if start and occurred < start:
            continue
        if end and occurred >= end:
            continue
        filtered.append(hit)
    return filtered


def main() -> int:
    payload = load_input()
    query = str(payload.get("query", "")).strip()
    if not query:
        print(json.dumps({"status": "ok", "hits": []}))
        return 0

    limit = int(payload.get("limit", 20))
    limit = max(1, min(limit, 100))
    start = parse_iso(payload.get("start") if isinstance(payload.get("start"), str) else None)
    end = parse_iso(payload.get("end") if isinstance(payload.get("end"), str) else None)

    user_id = os.getenv("ABOUT_TIME_MEM0_USER_ID", "about-time-user")
    agent_id = os.getenv("ABOUT_TIME_MEM0_AGENT_ID", "about-time-tracker")
    openrouter_key = (
        os.getenv("ABOUT_TIME_OPENROUTER_API_KEY")
        or os.getenv("OPENROUTER_API_KEY")
        or os.getenv("OPENAI_API_KEY")
    )

    if not openrouter_key:
        print(json.dumps({"status": "ok", "hits": []}))
        return 0

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

    try:
        raw_hits = call_search(memory, query=query, user_id=user_id, agent_id=agent_id, limit=limit)
    except Exception as exc:
        print(json.dumps({"status": "error", "error": f"mem0 search failed: {exc}"}))
        return 1

    hits = [normalize_hit(hit) for hit in raw_hits]
    hits = [hit for hit in hits if hit.get("memory")]
    hits = filter_hits_by_time(hits, start=start, end=end)
    print(json.dumps({"status": "ok", "hits": hits[:limit]}, default=str))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(json.dumps({"status": "error", "error": str(exc)}))
        raise
