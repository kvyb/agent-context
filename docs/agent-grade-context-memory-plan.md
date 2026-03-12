# About Time: Agent-Grade Context + Memory Plan

Date: 2026-03-10  
Status: Proposed implementation roadmap

## 1. Objective

Evolve About Time from a strong activity tracker into:

1. a reliable user-facing time product, and
2. a reusable perception + memory infrastructure for agents.

Core flow:

`screen/audio capture -> evidence extraction -> structured events -> memory writes -> semantic retrieval -> overview UX + agent context API`

## 2. Product Positioning (Dual-Layer)

1. User layer: automatic time tracking and reports (Timing/Toggl-like UX).
2. Infrastructure layer: semantic context capture and durable memory (Mem0 + SQLite).

This keeps the product understandable while enabling agent-grade capabilities.

## 3. Design Principles

1. Local-first capture and durable queues.
2. Evidence-first summaries (no hallucinated detail).
3. Structured outputs over freeform prose.
4. Mem0-backed semantic recall with deterministic local fallback.
5. Clear layer boundaries for maintainability.
6. Observable quality (specificity, confidence, retries, latency, cost).

## 4. Current Gaps (From Existing Codebase)

1. Memory query path is mostly SQLite keyword matching, not Mem0-first semantic retrieval.
2. Mem0 writes are summary-heavy and miss issue-level structured detail.
3. Interval/hour synthesis schema is shallow (`summary/entities/insufficient_evidence`).
4. Hour summaries are computed but not surfaced as primary overview in UI.
5. Docs describe features but not the architecture as an agent-compatible perception layer.
6. Some files are too broad in scope (harder to maintain/test).

## 5. Prioritized Roadmap

## Phase 1 (Priority 1): Prompt + Schema Hardening

Goal: increase semantic specificity and consistency before changing retrieval/UI.

### Scope

1. Introduce strict V2 schemas for interval/hour synthesis:
   - `task_segments[]` with:
     - `task`
     - `issue_or_goal`
     - `actions[]`
     - `outcome`
     - `next_step`
     - `confidence` (0-1)
     - `evidence_refs[]` (timestamps/artifact IDs)
     - `project`, `workspace`, `repo`, `doc`, `url` (optional)
2. Keep screenshot/audio artifact schema strict and compatible; enforce minimum evidence detail.
3. Add prompt version tags to every LLM write.
4. Add parser/validator layer so malformed JSON never leaks to UI.

### Files to touch

1. `Sources/AboutTimeCLI/OpenRouterClient.swift`
2. `Sources/AboutTimeCLI/Models.swift`
3. `Sources/AboutTimeCLI/HourlyActivityReporter.swift`
4. `Sources/AboutTimeCLI/SQLiteStore.swift`

### Done criteria

1. V2 schemas are used in per-app interval and hour synthesis calls.
2. Parsed outputs are typed and persisted with prompt version metadata.
3. Fallback behavior remains deterministic (`insufficient evidence`) when schema cannot be satisfied.
4. Golden tests validate at least 10 response-shape variants (clean JSON, fenced JSON, partial JSON, malformed).

## Phase 2 (Priority 2): Structured Memory Model + Writes

Goal: store queryable, issue-level memories instead of only prose summaries.

### Scope

1. Add typed memory record model (`task_segment`).
2. Persist both:
   - raw evidence timeline (already exists), and
   - normalized semantic segments (new).
3. Upgrade Mem0 ingestion payload:
   - `content`: concise task segment statement
   - metadata: app/project/repo/doc/url/entities/confidence/time range/evidence refs
4. Ensure idempotent keys (`memory_id`) to avoid duplicates during replay.

### Files to touch

1. `Sources/AboutTimeCLI/Models.swift`
2. `Sources/AboutTimeCLI/HourlyActivityReporter.swift`
3. `Sources/AboutTimeCLI/SQLiteStore.swift` (new table for task segments)
4. `scripts/mem0_ingest.py`

### Done criteria

1. Each finalized interval/hour emits `task_segment` memories.
2. Mem0 metadata contains enough fields for semantic retrieval and filtering.
3. Replay remains durable and idempotent after reconnect/restart.

## Phase 3 (Priority 3): Mem0-First Retrieval with Local Fallback

Goal: memory queries answer "what was worked on" semantically, not just keyword text hits.

### Scope

1. Add `scripts/mem0_search.py` bridge.
2. Update memory query service flow:
   - try Mem0 semantic search first,
   - merge/rank with local structured memory rows,
   - fallback to SQLite-only when Mem0 unavailable.
3. Add date/app/project filters in query resolver.

### Files to touch

1. `Sources/AboutTimeCLI/ScreenOCR.swift` (rename to `MemoryQueryService.swift`)
2. `Sources/AboutTimeCLI/EventLogger.swift` (or dedicated Mem0 client wrapper)
3. `scripts/mem0_search.py`
4. `Sources/AboutTimeCLI/SQLiteStore.swift`

### Done criteria

1. Queries like "what issue did I debug in Orion today?" return task/issue/outcome-level answers.
2. Offline mode still returns local results.
3. Retrieval latency remains bounded (target: p95 < 2.5s for UI query).

## Phase 4 (Priority 4): Overview-First UI, Chronology as Drill-Down

Goal: make high-level "what got done" primary; timeline remains available for auditability.

### Scope

1. Add hour/day overview cards:
   - top tasks
   - issues/goals
   - outcomes
   - next steps
2. Keep chronological evidence panel as expandable secondary layer.
3. Add quick "why" links from overview items to evidence refs.

### Files to touch

1. `Sources/AboutTimeCLI/MenuBarDashboardApp.swift` (or extracted view files)
2. `Sources/AboutTimeCLI/TrackerRuntime.swift`

### Done criteria

1. User can read hour/day outcomes without opening raw evidence list.
2. Clicking overview item reveals supporting evidence chronology.

## Phase 5 (Priority 5): Agent Context API Surface

Goal: expose stable programmatic interfaces for external agents.

### Scope

1. Add service methods:
   - `getCurrentContext()`
   - `getRecentActivity(range:)`
   - `retrieveRelatedMemories(query:, filters:)`
2. Keep API read-only initially.
3. Add lightweight CLI endpoints for testing.

### Files to touch

1. `Sources/AboutTimeCLI/TrackerRuntime.swift`
2. new `Sources/AboutTimeCLI/AgentContextService.swift`
3. `Sources/AboutTimeCLI/main.swift` (optional CLI hooks)

### Done criteria

1. Agent context calls return structured, date-scoped results.
2. No UI dependencies in API layer.

## Phase 6 (Priority 6): Documentation + Repository Messaging

Goal: clearly communicate product + infrastructure architecture.

### Scope

1. Rewrite `README.md`:
   - overview
   - architecture
   - event pipeline
   - memory integration
   - agent integration
   - examples
2. Add `docs/architecture.md` with explicit system flow.
3. Add schema docs for artifact/interval/hour/memory records.

### Done criteria

1. README positioning sentence is explicit:
   - "automatic time tracker powered by screen understanding and memory."
2. Architecture docs map exactly to implemented modules.

## 6. Codebase Maintainability Plan (Cross-Cutting)

1. Split large files by responsibility:
   - move memory query service out of `ScreenOCR.swift`
   - separate dashboard views from store logic
   - isolate OpenRouter schema builders from network transport
2. Keep strict model boundaries:
   - capture models
   - analysis models
   - memory models
   - UI view models
3. Introduce thin protocols for testability:
   - `LLMClient`
   - `MemoryStore`
   - `SemanticRetriever`
4. Centralize constants:
   - prompt IDs/versions
   - retry/backoff policies
   - schema names

## 7. Performance + Reliability Guardrails

1. Keep capture path non-blocking and queue-backed (already mostly done).
2. Ensure bounded retries and dead-letter visibility for repeated parse failures.
3. Add per-stage metrics:
   - capture count
   - analysis success/failure
   - parse validity rate
   - summary specificity score
   - Mem0 success/retry rate
   - query latency
4. Keep memory footprint under target and avoid loading full-day raw evidence unless needed.

## 8. Quality Gates and Tests

### Unit tests

1. JSON decoding/validation for all schema versions.
2. Task/issue extraction fallback logic.
3. Memory query ranking and filtering.

### Integration tests

1. Artifact -> interval/hour -> memory write chain.
2. Offline queue replay and idempotency.
3. Mem0 unavailable -> local fallback.

### Acceptance checks

1. "What exactly was done?" answers include task + issue + outcome in most hours.
2. `insufficient evidence` appears only when truly warranted.
3. Hour overview is useful without opening raw chronology.

## 9. Suggested Execution Order

1. Phase 1 (prompt/schema hardening)  
2. Phase 2 (structured memory writes)  
3. Phase 3 (Mem0-first retrieval)  
4. Phase 4 (overview-first UI)  
5. Phase 6 (docs) and Phase 5 (agent API) in parallel

Reason: prompt/schema quality is the root dependency for good memory and retrieval.

## 10. Immediate Next Sprint (Recommended)

1. Implement Phase 1 + Phase 2 together behind schema version `v2`.
2. Add migration-safe storage for `task_segment` rows.
3. Backfill recent intervals/hours with `v2` synthesis on demand (manual trigger).

This gives fast product impact: better descriptions now, better memory search next.
