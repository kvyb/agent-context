---
name: agent-context-memory
description: Query local Agent Context memory (Mem0 + BM25) to answer what the user worked on, what changed, and what may be unfinished.
argument-hint: "<question>"
---

# Agent Context Memory

Use this skill when the user asks about their work history, timeline, changes, or unfinished items.

## Run query

Run:

```bash
./scripts/agent_context_query.sh "$ARGUMENTS"
```

This returns JSON from Agent Context with keys like:
- `answer`
- `key_points`
- `supporting_events`
- `insufficient_evidence`
- `time_scope`

## Response style

- Lead with `answer`.
- Include 3-6 `key_points` when present.
- Include relevant `supporting_events` as evidence.
- Include the `time_scope.label` and/or dates when available.
- If `insufficient_evidence` is `true`, say so clearly and suggest narrowing the question by app/project/day.
