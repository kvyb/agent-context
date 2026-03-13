#!/usr/bin/env python3
"""Mem0 semantic search bridge for About Time.

Reads one JSON payload from stdin:
{
  "query": "...",                  # optional fallback
  "queries": ["...", "..."],       # preferred
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


def parse_queries(payload: dict[str, Any]) -> list[str]:
    output: list[str] = []
    seen: set[str] = set()

    raw_queries = payload.get("queries")
    if isinstance(raw_queries, list):
        for item in raw_queries:
            if not isinstance(item, str):
                continue
            normalized = item.strip()
            if not normalized:
                continue
            key = normalized.lower()
            if key in seen:
                continue
            seen.add(key)
            output.append(normalized)
            if len(output) >= 10:
                return output

    fallback_query = payload.get("query")
    if isinstance(fallback_query, str):
        normalized = fallback_query.strip()
        if normalized and normalized.lower() not in seen:
            output.append(normalized)

    return output[:10]


def parse_score(value: Any) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except Exception:
            return 0.0
    return 0.0


def build_mem0_config() -> dict[str, Any]:
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


def normalize_hit(raw: dict[str, Any], retrieved_query: str, query_rank: int) -> dict[str, Any]:
    metadata = raw.get("metadata") if isinstance(raw.get("metadata"), dict) else {}
    memory_text = raw.get("memory") or raw.get("text") or raw.get("content") or ""
    if not isinstance(memory_text, str):
        memory_text = str(memory_text)

    app_name = raw.get("app_name") or metadata.get("app_name")
    project = raw.get("project") or metadata.get("project")
    occurred_at = raw.get("occurred_at") or metadata.get("occurred_at")

    normalized_metadata = {k: str(v) for k, v in metadata.items()}
    normalized_metadata["retrieved_query"] = retrieved_query
    normalized_metadata["query_rank"] = str(query_rank)

    return {
        "id": raw.get("id"),
        "score": raw.get("score"),
        "memory": memory_text.strip(),
        "app_name": app_name if isinstance(app_name, str) else None,
        "project": project if isinstance(project, str) else None,
        "occurred_at": occurred_at if isinstance(occurred_at, str) else None,
        "metadata": normalized_metadata,
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


def dedupe_and_sort_hits(hits: list[dict[str, Any]]) -> list[dict[str, Any]]:
    best: dict[str, dict[str, Any]] = {}

    for hit in hits:
        memory = hit.get("memory")
        if not isinstance(memory, str) or not memory.strip():
            continue

        occurred_at = hit.get("occurred_at")
        occurred_key = occurred_at if isinstance(occurred_at, str) else ""
        raw_id = hit.get("id")
        if isinstance(raw_id, str) and raw_id.strip():
            key = f"id:{raw_id.strip()}"
        else:
            key = f"text:{memory.strip().lower()}::{occurred_key}"

        existing = best.get(key)
        if existing is None:
            best[key] = hit
            continue

        existing_score = parse_score(existing.get("score"))
        candidate_score = parse_score(hit.get("score"))
        if candidate_score > existing_score:
            best[key] = hit

    def query_rank(hit: dict[str, Any]) -> int:
        metadata = hit.get("metadata")
        if isinstance(metadata, dict):
            rank_raw = metadata.get("query_rank")
            if isinstance(rank_raw, str) and rank_raw.isdigit():
                return int(rank_raw)
        return 99

    def occurred_ts(hit: dict[str, Any]) -> float:
        raw = hit.get("occurred_at")
        if not isinstance(raw, str):
            return 0.0
        parsed = parse_iso(raw)
        if parsed is None:
            return 0.0
        return parsed.timestamp()

    return sorted(
        best.values(),
        key=lambda hit: (-parse_score(hit.get("score")), query_rank(hit), -occurred_ts(hit)),
    )


def main() -> int:
    payload = load_input()
    queries = parse_queries(payload)
    if not queries:
        print(json.dumps({"status": "ok", "hits": []}))
        return 0

    limit = int(payload.get("limit", 20))
    limit = max(1, min(limit, 100))
    start = parse_iso(payload.get("start") if isinstance(payload.get("start"), str) else None)
    end = parse_iso(payload.get("end") if isinstance(payload.get("end"), str) else None)

    user_id = os.getenv("AGENT_CONTEXT_MEM0_USER_ID", "agent-context-user")
    agent_id = os.getenv("AGENT_CONTEXT_MEM0_AGENT_ID", "agent-context-tracker")
    openrouter_key = (
        os.getenv("AGENT_CONTEXT_OPENROUTER_API_KEY")
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

    collected: list[dict[str, Any]] = []
    for index, query in enumerate(queries):
        try:
            raw_hits = call_search(memory, query=query, user_id=user_id, agent_id=agent_id, limit=limit)
        except Exception as exc:
            print(json.dumps({"status": "error", "error": f"mem0 search failed for query '{query}': {exc}"}))
            return 1

        normalized_hits = [normalize_hit(hit, retrieved_query=query, query_rank=index) for hit in raw_hits]
        normalized_hits = [hit for hit in normalized_hits if hit.get("memory")]
        collected.extend(normalized_hits)

    hits = filter_hits_by_time(collected, start=start, end=end)
    hits = dedupe_and_sort_hits(hits)
    print(json.dumps({"status": "ok", "hits": hits[:limit]}, default=str))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(json.dumps({"status": "error", "error": str(exc)}))
        raise
