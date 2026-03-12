# About Time: Ideal Product Plan (vNext)

## 1) Product Purpose

Build a native macOS activity tracker that produces reporting-grade work logs automatically:

- what was done
- in which app/window/workspace/project
- when and for how long
- with concise, specific summaries (not generic filler)

## 2) What / How / Why

| What we want | How it works | Why it exists |
| --- | --- | --- |
| Accurate app-time tracking across rapid switching | Track frontmost app activation/deactivation and store second-level intervals by app/window | Time data must be trustworthy before any LLM summary is useful |
| High-signal visual evidence | Capture screenshot 3s after app activation, then every 30s while still active | Delayed first shot avoids transition noise; periodic shots preserve context during long focus sessions |
| Robust meeting evidence | Capture meeting audio only when user explicitly starts recording, in rolling 2-minute chunks | Guarantees user control and avoids unwanted automatic call detection/capture |
| Real-time quality feedback | Analyze screenshots/audio continuously and attach timestamped “live analyses” to current interval | User can verify quality while recording, not only after stop/restart |
| Reporting-grade summaries | Run per-app interval synthesis first, then hour-level synthesis using per-app outputs + timeline | Two-pass hierarchy improves specificity and keeps hour summaries coherent |
| Long-term recall | Write structured memories to SQLite + Mem0 (local Qdrant + history DB) | Enables natural-language recall across day/week/month and project-level reporting |

## 3) Core Functional Behavior

### Capture layer

- Frontmost app tracking is always on while recording.
- Screenshot policy:
  - activation + 3 seconds (if app still active)
  - every 30 seconds while same app stays active
  - full desktop frame, compressed WebP with text-legibility targets
- Audio policy:
  - no auto-detect of Zoom/Meet/Huddles
  - audio recording starts only from explicit UI action (`Start Transcript`)
  - audio recording stops only from explicit UI action (`Stop Transcript`) or app stop
  - rolling chunk files (2 minutes each), uploaded/analyzed incrementally
  - no exclusive mic ownership that could block conferencing apps

### Analysis layer

- Artifact-level analysis:
  - each screenshot/audio chunk receives its own timestamped analysis
  - stored as evidence records, not only final prose
- Interval-level analysis (10-minute windows):
  - per-app synthesis from evidence inside interval
  - must reference concrete observed UI/audio facts
- Hour-level analysis:
  - summarize from finalized per-app interval analyses + time timeline
  - output dry, concise, project-oriented report text
- LLM transport:
  - all inference calls go through OpenRouter
  - default model: `google/gemini-3.1-flash-lite-preview`
  - reasoning mode enabled with effort `medium`

### Memory layer

- Every finalized interval/hour writes to local SQLite.
- Mem0 ingestion runs on normalized description payloads (`infer=True` flow).
- All memory writes are durable and queryable by app/project/date/entity.

## 4) LLM Calls via OpenRouter (Required)

### Endpoint and auth

- Endpoint: `https://openrouter.ai/api/v1/chat/completions`
- Auth: `Authorization: Bearer <OPENROUTER_API_KEY>`
- Key source: settings UI (persisted), then env fallback

### Call graph

1. Screenshot artifact call (near real-time)
   - input: one screenshot + app/time/window metadata
   - output: concise factual description + extracted entities (project/workspace/topic)
2. Audio chunk call (every 2 minutes while transcript mode is ON)
   - input: one audio chunk + app/time metadata
   - output: transcript + concise meeting/action summary + entities
3. Per-app interval synthesis call (10-minute interval, per app)
   - input: that app's artifact outputs + timeline slices
   - output: reporting-grade app summary for the interval
4. Interval/hour synthesis call
   - input: per-app interval outputs + timeline
   - output: dry, specific narrative for report rows

### Rules

- Never skip direct artifact calls when artifact exists.
- Prefer evidence-first summaries; if evidence is missing, return explicit `insufficient evidence`.
- Token usage must be captured per call from response `usage` and aggregated in app settings.
- Retries must be bounded with backoff; failed artifacts remain in retry queue.

## 5) Manual Meeting Transcript Spec

No automatic call detection or auto-popup flow.

### Trigger

- User explicitly clicks transcript controls in About Time UI:
  - `Start Transcript`
  - `Stop Transcript`

### Behavior

- While transcript mode is active:
  - capture system audio in 2-minute chunks
  - send chunks incrementally for Gemini 3.1 Flash Lite transcription/analysis
  - attach timestamped transcript snippets to the active interval
- On stop:
  - finalize the last partial chunk
  - run interval/hour synthesis with transcript evidence included

### UI

- Primary visible control in app window and menu bar menu.
- Optional compact status chip (recording timer), but no auto-start prompt.

## 6) Quality Bar (Non-negotiable)

Summaries must:

- name concrete tasks, documents, pages, files, or meeting topics when visible/audible
- map activity to project/workspace/employer when evidence exists
- explicitly say `insufficient evidence` only when truly missing
- never hallucinate details
- avoid repetitive “About Time UI” contamination for other apps

## 7) Performance & Reliability Targets

- CPU overhead while idle tracking: under 2-3% average
- Memory footprint: under 250 MB
- Screenshot pipeline: non-blocking (async queue + bounded retries)
- Audio pipeline: rolling segments + resumable upload/analysis queue
- Quit behavior:
  - graceful drain with visible progress modal
  - hard timeout fallback with resumable pending-work journal

## 8) UX Requirements

- Menu bar app only (no Dock icon by default).
- Right-click menu:
  - `Start Recording`
  - `Stop Recording`
  - `Quit`
- Main dashboard:
  - day view with 0-24 hour rows
  - app blocks with icons and durations
  - click block opens interval details with ordered timestamped analyses
  - close button must always be visible and functional
- Settings:
  - OpenRouter key management
  - token/cost usage counters (input/output/audio)
  - capture policy toggles and consent behavior

## 9) Delivery Plan (Suggested)

1. Stabilize capture correctness (screenshots/audio + contamination filters).
2. Stabilize analysis specificity (prompt + evidence routing + anti-generic rules).
3. Make UI fully reactive with live interval updates.
4. Add manual transcript controls flow and chunk-finalization UX.
5. Add memory query panel (`What did I do today?`, `What did I do on Monday in Zoom?`).
6. Harden shutdown/resume state machine and backfill/retry queue.

## 10) Success Criteria

- User can trust app-time totals vs observed behavior.
- Per-app descriptions are specific in the majority of intervals.
- Hour summaries are useful enough to paste directly into work logs.
- Natural-language memory queries return correct, date-scoped answers.
- App runs continuously with low footprint and no conference-audio conflicts.
