# Agent Context Internal Agent CLI (Query Route)

This document is for AI agents and automation tools that need to query Agent Context memories through the local CLI.

## Purpose

Use the query route to ask natural-language questions about tracked work context, with retrieval grounded on:
- Mem0 semantic retrieval
- BM25 lexical retrieval over local Mem0-ingested memory rows

## Command

```bash
agent-context --query "<natural language question>" [--format text|json]
```

## Flags

- `--query "<text>"` (required): natural-language question.
- `--format text|json` (optional):
  - `text` default.
  - `json` for machine consumption.

## Environment / Runtime Requirements

- Agent Context data directory must be accessible (`ABOUT_TIME_HOME` or default `~/.about-time`).
- Mem0 must be enabled in settings.
- OpenRouter/OpenAI-compatible API key must be configured in settings or env.

## Exit Behavior

- `0`: command executed and returned an answer payload (including insufficient-evidence answers).
- `1`: CLI/runtime failure (bad args, startup failure, unrecoverable runtime error).

## Text Output Example

```text
For this week at ManyChat, you reviewed ai-service PRs and continued eval-platform troubleshooting.

Key points:
- Reviewed PR #556 and #557 in ai-service.
- Investigated Agenta authentication issues.

Supporting events:
- 2026-03-12: Reviewed ai-service PRs.
```

## JSON Output Example

```json
{
  "query": "what is the status of my work at ManyChat for this week, things done and pending?",
  "answer": "For this week at ManyChat, you reviewed ai-service PRs and continued eval-platform troubleshooting.",
  "key_points": [
    "Reviewed PR #556 and #557 in ai-service."
  ],
  "supporting_events": [
    "2026-03-12: Reviewed ai-service PRs."
  ],
  "insufficient_evidence": false,
  "sources": {
    "mem0_semantic_count": 24,
    "bm25_store_count": 18
  },
  "time_scope": {
    "start": "2026-03-09T00:00:00Z",
    "end": "2026-03-16T00:00:00Z",
    "label": "this week"
  },
  "generated_at": "2026-03-12T08:20:13Z"
}
```

## Stable JSON Contract (v1)

Required top-level keys:
- `query` string
- `answer` string
- `key_points` string[]
- `supporting_events` string[]
- `insufficient_evidence` boolean
- `sources.mem0_semantic_count` integer
- `sources.bm25_store_count` integer
- `time_scope.start` string (ISO8601 or empty)
- `time_scope.end` string (ISO8601 or empty)
- `time_scope.label` string
- `generated_at` string (ISO8601)

## Error Semantics

- Empty query:
  - text: `Enter a question to query memory.`
  - json: same message in `answer`, `insufficient_evidence=true`.
- Mem0 disabled:
  - answer explains Mem0 is disabled.
- Missing API key:
  - answer explains OpenRouter API key is missing.
- No matching data:
  - answer: `No matching memories found in Mem0/BM25 memory stores.`
  - `insufficient_evidence=true`.

## Prompt Examples for Agents

- `what did I work on today in Codex?`
- `when did I work on ManyChat this week and what changed?`
- `what did I forget to finalize this week?`
- `what are the unresolved follow-ups related to eval-platform from yesterday?`
- `what issues were discussed in meetings this week?`
