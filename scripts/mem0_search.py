#!/usr/bin/env python3
"""Mem0 semantic search bridge for About Time."""

from __future__ import annotations

import json
import inspect
import os
from datetime import datetime, timezone
from typing import Any

from mem0_common import (
    build_mem0_config,
    iso8601_utc,
    load_payload,
    parse_iso,
    stringify_metadata_value,
    unique_strings,
    unix_timestamp,
)


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


def query_prefers_keyword_coverage(query: str, payload: dict[str, Any]) -> bool:
    text = query.strip()
    if not text:
        return False

    if any(payload.get(key) for key in ["project", "projects", "app_name", "app_names", "categories"]):
        return True

    technical_markers = ["/", ".", "_", "-", "#", ":", "sql", "api", "llm", "rag", "ndcg", "pr "]
    lowered = text.lower()
    if any(marker in lowered for marker in technical_markers):
        return True

    tokens = [token for token in text.split() if token]
    return any(any(char.isdigit() or char.isupper() for char in token) for token in tokens)


def should_use_rerank(payload: dict[str, Any], final_limit: int) -> bool:
    raw_queries = payload.get("queries")
    query_count = len([item for item in raw_queries if isinstance(item, str) and item.strip()]) if isinstance(raw_queries, list) else 1
    return query_count <= 2


def rerank_candidate_limit(final_limit: int) -> int:
    bounded_limit = max(1, min(final_limit, 100))
    return min(max(bounded_limit + 2, 6), 8)


def build_search_option_sets(
    *,
    query: str,
    payload: dict[str, Any],
    final_limit: int,
    filters: dict[str, Any] | None,
    supported_parameters: set[str],
) -> list[dict[str, Any]]:
    rerank_supported = "rerank" in supported_parameters and should_use_rerank(payload, final_limit)
    keyword_supported = "keyword_search" in supported_parameters and query_prefers_keyword_coverage(query, payload)

    option_sets: list[dict[str, Any]] = []
    standard_limit = max(1, min(final_limit, 100))
    expanded_limit = rerank_candidate_limit(standard_limit) if rerank_supported else standard_limit

    def append_option(option: dict[str, Any]) -> None:
        filtered_option = {key: value for key, value in option.items() if key in supported_parameters}
        if filtered_option not in option_sets:
            option_sets.append(filtered_option)

    if filters and rerank_supported:
        option: dict[str, Any] = {"limit": expanded_limit, "filters": filters, "rerank": True}
        if keyword_supported:
            option["keyword_search"] = True
        append_option(option)

    if filters:
        option = {"limit": standard_limit, "filters": filters}
        if keyword_supported:
            option["keyword_search"] = True
        append_option(option)

    if rerank_supported:
        option = {"limit": expanded_limit, "rerank": True}
        if keyword_supported:
            option["keyword_search"] = True
        append_option(option)

    if keyword_supported:
        append_option({"limit": standard_limit, "keyword_search": True})

    append_option({"limit": standard_limit})
    return option_sets


def parse_score(value: Any) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except Exception:
            return 0.0
    return 0.0


def parse_timestamp(value: Any) -> datetime | None:
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(float(value), tz=timezone.utc)
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        if text.isdigit():
            return datetime.fromtimestamp(float(text), tz=timezone.utc)
        try:
            return datetime.fromtimestamp(float(text), tz=timezone.utc)
        except Exception:
            return parse_iso(text)
    return None


def extract_occurred_at(hit: dict[str, Any]) -> datetime | None:
    direct_candidates = [
        hit.get("occurred_at"),
        hit.get("timestamp"),
        hit.get("event_timestamp"),
    ]
    for candidate in direct_candidates:
        parsed = parse_iso(candidate) if isinstance(candidate, str) else parse_timestamp(candidate)
        if parsed is not None:
            return parsed

    metadata = hit.get("metadata")
    if not isinstance(metadata, dict):
        return None

    for key in ["occurred_at", "event_timestamp", "timestamp"]:
        candidate = metadata.get(key)
        parsed = parse_iso(candidate) if isinstance(candidate, str) else parse_timestamp(candidate)
        if parsed is not None:
            return parsed
    return None


def build_search_filters(payload: dict[str, Any], start: datetime | None, end: datetime | None) -> dict[str, Any] | None:
    clauses: list[dict[str, Any]] = []

    time_filter: dict[str, Any] = {}
    if start is not None:
        time_filter["gte"] = unix_timestamp(start)
    if end is not None:
        time_filter["lt"] = unix_timestamp(end)
    if time_filter:
        clauses.append({"event_timestamp": time_filter})

    for payload_key, filter_key in [
        ("projects", "project"),
        ("project", "project"),
        ("app_names", "app_name"),
        ("app_name", "app_name"),
        ("scopes", "scope"),
        ("scope", "scope"),
        ("categories", "categories"),
    ]:
        raw_value = payload.get(payload_key)
        values = unique_strings(raw_value if isinstance(raw_value, list) else [raw_value] if raw_value is not None else [])
        if not values:
            continue
        if len(values) == 1:
            clauses.append({filter_key: values[0]})
        else:
            clauses.append({filter_key: {"in": values}})

    extra_filters = payload.get("filters")
    if isinstance(extra_filters, dict) and extra_filters:
        clauses.append(extra_filters)

    if not clauses:
        return None
    if len(clauses) == 1:
        return clauses[0]
    return {"AND": clauses}


def search_attempts(
    memory,
    query: str,
    payload: dict[str, Any],
    limit: int,
    scope_kwargs: dict[str, Any],
    filters: dict[str, Any] | None,
) -> list[dict[str, Any]]:
    had_success = False
    last_error = None
    supported_parameters = set(inspect.signature(memory.search).parameters.keys())

    option_sets = build_search_option_sets(
        query=query,
        payload=payload,
        final_limit=limit,
        filters=filters,
        supported_parameters=supported_parameters,
    )

    for extra_kwargs in option_sets:
        merged_kwargs = {**scope_kwargs, **extra_kwargs}
        attempts = [
            lambda kwargs=merged_kwargs: memory.search(query=query, **kwargs),
            lambda kwargs=merged_kwargs: memory.search(query, **kwargs),
        ]
        for attempt in attempts:
            try:
                raw = attempt()
                had_success = True
            except Exception as exc:  # noqa: PERF203
                last_error = exc
                continue

            rows: list[dict[str, Any]]
            if isinstance(raw, list):
                rows = [row for row in raw if isinstance(row, dict)]
            elif isinstance(raw, dict):
                results = raw.get("results")
                rows = [row for row in results if isinstance(row, dict)] if isinstance(results, list) else []
            else:
                rows = []

            if rows:
                return rows

    if had_success:
        return []
    if last_error is not None:
        raise last_error
    return []


def call_search(
    memory,
    query: str,
    payload: dict[str, Any],
    user_id: str,
    agent_id: str,
    limit: int,
    filters: dict[str, Any] | None,
) -> list[dict[str, Any]]:
    attempts: list[dict[str, Any]] = []
    if user_id and agent_id:
        attempts.append({"user_id": user_id, "agent_id": agent_id})
    if user_id:
        attempts.append({"user_id": user_id})
    if agent_id:
        attempts.append({"agent_id": agent_id})
    if not attempts:
        attempts.append({})

    seen: set[str] = set()
    collected: list[dict[str, Any]] = []
    for scope_kwargs in attempts:
        key = json.dumps(scope_kwargs, sort_keys=True)
        if key in seen:
            continue
        seen.add(key)
        rows = search_attempts(
            memory,
            query=query,
            payload=payload,
            limit=limit,
            scope_kwargs=scope_kwargs,
            filters=filters,
        )
        if not rows:
            continue
        collected.extend(rows)
        if len(collected) >= limit:
            break
    return collected


def normalize_hit(raw: dict[str, Any], retrieved_query: str, query_rank: int) -> dict[str, Any]:
    metadata = raw.get("metadata") if isinstance(raw.get("metadata"), dict) else {}
    memory_text = raw.get("memory") or raw.get("text") or raw.get("content") or ""
    if not isinstance(memory_text, str):
        memory_text = str(memory_text)

    normalized_metadata: dict[str, str] = {}
    for key, value in metadata.items():
        if not isinstance(key, str):
            continue
        rendered = stringify_metadata_value(value)
        if rendered:
            normalized_metadata[key] = rendered
    normalized_metadata["retrieved_query"] = retrieved_query
    normalized_metadata["query_rank"] = str(query_rank)

    occurred_at = extract_occurred_at(raw)
    occurred_at_text = iso8601_utc(occurred_at)
    if occurred_at_text:
        normalized_metadata.setdefault("occurred_at", occurred_at_text)

    app_name = raw.get("app_name") or metadata.get("app_name")
    project = raw.get("project") or metadata.get("project")

    return {
        "id": raw.get("id"),
        "score": raw.get("score"),
        "memory": memory_text.strip(),
        "app_name": app_name if isinstance(app_name, str) else None,
        "project": project if isinstance(project, str) else None,
        "occurred_at": occurred_at_text,
        "metadata": normalized_metadata,
    }


def filter_hits_by_time(hits: list[dict[str, Any]], start: datetime | None, end: datetime | None) -> list[dict[str, Any]]:
    if not start and not end:
        return hits

    filtered: list[dict[str, Any]] = []
    for hit in hits:
        occurred = extract_occurred_at(hit)
        if occurred is None:
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
        occurred = extract_occurred_at(hit)
        return occurred.timestamp() if occurred is not None else 0.0

    return sorted(
        best.values(),
        key=lambda hit: (-parse_score(hit.get("score")), query_rank(hit), -occurred_ts(hit)),
    )


def main() -> int:
    payload = load_payload()
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

    filters = build_search_filters(payload, start=start, end=end)

    collected: list[dict[str, Any]] = []
    for index, query in enumerate(queries):
        try:
            raw_hits = call_search(
                memory,
                query=query,
                payload=payload,
                user_id=user_id,
                agent_id=agent_id,
                limit=limit,
                filters=filters,
            )
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
