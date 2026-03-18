import Foundation
import ImageIO
import UniformTypeIdentifiers

private final class NetworkResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var error: Error?
    private var statusCode: Int?

    func set(data: Data?, error: Error?, statusCode: Int?) {
        lock.lock()
        self.data = data
        self.error = error
        self.statusCode = statusCode
        lock.unlock()
    }

    func snapshot() -> (data: Data?, error: Error?, statusCode: Int?) {
        lock.lock()
        let snapshot = (data, error, statusCode)
        lock.unlock()
        return snapshot
    }
}

struct OpenRouterCallResult: Sendable {
    let text: String
    let usage: LLMUsageEvent
}

final class OpenRouterClient: @unchecked Sendable {
    private let endpoint: URL
    private let multimodalModel: String
    private let audioModel: String
    private let textModel: String
    private let queryAgentModel: String
    private let reasoningEffort: String
    private let timeoutSeconds: TimeInterval
    private let appNameHeader: String?
    private let refererHeader: String?
    private let userIdentityAliases: [String]

    init(config: OpenRouterRuntimeConfig, settings: AppSettings) {
        endpoint = config.endpoint
        multimodalModel = AppSettings.normalizedOpenRouterModel(settings.openRouterModel.nilIfEmpty ?? config.model)
        audioModel = AppSettings.normalizedOpenRouterModel(settings.openRouterAudioModel.nilIfEmpty ?? multimodalModel)
        textModel = AppSettings.normalizedOpenRouterModel(settings.openRouterTextModel.nilIfEmpty ?? multimodalModel)
        queryAgentModel = "google/gemini-3-flash-preview"
        reasoningEffort = config.reasoningEffort
        timeoutSeconds = config.timeoutSeconds
        appNameHeader = settings.openRouterAppNameHeader
        refererHeader = settings.openRouterRefererHeader
        userIdentityAliases = AppSettings.normalizedAliases(settings.userIdentityAliases)
    }

    func analyzeScreenshot(metadata: ArtifactMetadata, apiKey: String) throws -> OpenRouterCallResult {
        let model = multimodalModel
        let webpData = try webPDataForLLM(from: metadata.path)
        let dataURI = "data:image/webp;base64,\(webpData.base64EncodedString())"
        let aliasList = userIdentityAliases.isEmpty ? "(none provided)" : userIdentityAliases.joined(separator: ", ")

        let systemPrompt = """
        You are an evidence extractor for a work-log tracker analyzing a desktop screenshot.
        Return strict JSON with keys: description, problem, success, user_contribution, suggestion_or_decision,
        status, confidence, project, workspace, task, evidence, entities, insufficient_evidence.
        Rules:
        - Use only concrete facts visible in the screenshot.
        - Metadata fields (app/window/url/workspace/project) are hints only, never primary evidence.
        - task MUST capture the exact current work item in a short phrase (4-14 words) when inferable.
        - If a visible thread title, doc title, PR title, issue title, or heading exists, map task from it.
        - task should be outcome-oriented (e.g. \"implement durable backfill queue replay\", \"review OpenRouter pricing for embeddings\").
        - description must be neutral/factual and always present.
        - If readable content exists, description should contain 1-3 sentences and at least 2 concrete on-screen details
          (filenames, command text, document titles, chat topics, UI labels, URLs, code symbols, settings labels).
        - Inference fields (problem, success, user_contribution, suggestion_or_decision) must be null when unsupported.
        - status must be one of: none, blocked, in_progress, resolved.
        - confidence is 0..1 and reflects confidence in inference fields.
        - project/workspace/task must be strings; use empty string when unknown.
        - evidence should contain visible clues that support inference claims.
        - Focus on task, document, page, file, workspace, project, and employer when visible.
        - Never hallucinate.
        - Do not mention Agent Context UI unless it is the active app itself.
        - Do not output generic boilerplate like \"user is active in APP\".
        - Avoid phrasing like \"the user is ...\". Prefer neutral wording like \"Reviewing ...\".
        - Infer likely authorship when possible, even if the user's alias is not visible.
        - In chat/email tools, treat outgoing-side message alignment, \"You/Me\" labels, composer ownership,
          first-person message text, and participant headers as authorship cues.
        - Use user identity aliases only as hints for authorship inference, never as proof by themselves.
        - If authorship is inferred, mention it briefly in description and add one explicit evidence item describing the cue.
        - If authorship is ambiguous, do not assert ownership.
        - Write in dry, specific report style, not conversational style.
        - If evidence is truly weak or unreadable, set insufficient_evidence=true and description exactly \"insufficient evidence\".
        """

        let userText = """
        Timestamp: \(iso8601(metadata.capturedAt))
        App: \(metadata.app.appName)
        Bundle: \(metadata.app.bundleID ?? "")
        Window title: \(metadata.window.title ?? "")
        Document: \(metadata.window.documentPath ?? "")
        URL: \(metadata.window.url ?? "")
        Workspace: \(metadata.window.workspace ?? "")
        Project: \(metadata.window.project ?? "")
        User identity aliases: \(aliasList)
        """

        let payload: [String: Any] = [
            "model": model,
            "reasoning": ["effort": reasoningEffort],
            "temperature": 0.1,
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "artifact_analysis",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": [
                            "description": ["type": "string"],
                            "problem": ["type": ["string", "null"]],
                            "success": ["type": ["string", "null"]],
                            "user_contribution": ["type": ["string", "null"]],
                            "suggestion_or_decision": ["type": ["string", "null"]],
                            "status": [
                                "type": "string",
                                "enum": ["none", "blocked", "in_progress", "resolved"]
                            ],
                            "confidence": ["type": "number"],
                            "project": ["type": "string"],
                            "workspace": ["type": "string"],
                            "task": ["type": "string"],
                            "evidence": ["type": "array", "items": ["type": "string"]],
                            "entities": ["type": "array", "items": ["type": "string"]],
                            "insufficient_evidence": ["type": "boolean"]
                        ],
                        "required": [
                            "description",
                            "problem",
                            "success",
                            "user_contribution",
                            "suggestion_or_decision",
                            "status",
                            "confidence",
                            "project",
                            "workspace",
                            "task",
                            "evidence",
                            "entities",
                            "insufficient_evidence"
                        ],
                        "additionalProperties": false
                    ]
                ]
            ],
            "messages": [
                ["role": "system", "content": systemPrompt],
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": userText],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": dataURI
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let response = try call(
            payload: payload,
            model: model,
            kind: "artifact_screenshot",
            apiKey: apiKey,
            timeoutSeconds: timeoutSeconds
        )
        return response
    }

    func analyzeAudioChunk(metadata: ArtifactMetadata, apiKey: String) throws -> OpenRouterCallResult {
        let model = audioModel
        let audioData = try Data(contentsOf: URL(fileURLWithPath: metadata.path))
        let format = URL(fileURLWithPath: metadata.path).pathExtension.lowercased()

        let systemPrompt = """
        You are an evidence extractor for meeting audio.
        Return strict JSON with keys: summary, transcript, entities, insufficient_evidence.
        Rules:
        - Transcript must be detailed and near-verbatim, not concise.
        - Preserve important phrasing and include speaker turns using labels like \"S1:\", \"S2:\" when speakers can be distinguished.
        - Do not omit concrete details (numbers, names, dates, deadlines, commitments, blockers, decisions, tools, file names).
        - If words are uncertain, mark them inline as \"[unclear]\" instead of dropping surrounding context.
        - Summary must be thorough and structured with these labeled lines in order:
          Topics:
          Decisions:
          Action Items:
          Open Questions/Risks:
        - In Action Items, include owner when inferable; otherwise use \"owner unknown\".
        - Set insufficient_evidence=true only when most of the audio is unintelligible or irrelevant noise.
        - If insufficient_evidence=true, summary and transcript must both be exactly \"insufficient evidence\".
        - Never invent details.
        """

        let userText = """
        Timestamp: \(iso8601(metadata.capturedAt))
        App: \(metadata.app.appName)
        Window title: \(metadata.window.title ?? "")
        """

        let payload: [String: Any] = [
            "model": model,
            "reasoning": ["effort": reasoningEffort],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "audio_analysis",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": [
                            "summary": ["type": "string"],
                            "transcript": ["type": "string"],
                            "entities": ["type": "array", "items": ["type": "string"]],
                            "insufficient_evidence": ["type": "boolean"]
                        ],
                        "required": ["summary", "transcript", "entities", "insufficient_evidence"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "messages": [
                ["role": "system", "content": systemPrompt],
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": userText],
                        [
                            "type": "input_audio",
                            "input_audio": [
                                "format": format.isEmpty ? "wav" : format,
                                "data": audioData.base64EncodedString()
                            ]
                        ]
                    ]
                ]
            ]
        ]

        return try call(
            payload: payload,
            model: model,
            kind: "artifact_audio",
            apiKey: apiKey,
            timeoutSeconds: timeoutSeconds
        )
    }

    func synthesizePerAppInterval(
        appName: String,
        bundleID: String?,
        bucketStart: Date,
        bucketEnd: Date,
        evidence: [StoredEvidenceRecord],
        timeline: [TimelineSlice],
        apiKey: String
    ) throws -> OpenRouterCallResult {
        let model = textModel
        let evidenceLines = evidence.map { record in
            let analysis = record.analysis?.summary ?? "pending artifact analysis"
            let entities = record.analysis?.entities.joined(separator: ",") ?? ""
            let task = record.analysis?.task ?? ""
            let project = record.analysis?.project ?? ""
            let workspace = record.analysis?.workspace ?? ""
            return "- [\(iso8601(record.metadata.capturedAt))] id=\(record.metadata.id) \(record.metadata.kind.rawValue): \(analysis) | task=\(task) | project=\(project) | workspace=\(workspace) | entities=\(entities)"
        }.joined(separator: "\n")

        let timelineLines = timeline
            .filter { $0.appName == appName && $0.bundleID == bundleID }
            .map { slice in
                "- \(iso8601(slice.startTime)) to \(iso8601(slice.endTime))"
            }
            .joined(separator: "\n")

        let systemPrompt = """
        Produce a reporting-grade app interval synthesis.
        Return strict JSON with keys: summary, entities, insufficient_evidence, task_segments.
        Rules:
        - Must reference concrete evidence from artifact analyses.
        - If evidence exists but is weak, still describe only what is known and set insufficient_evidence=true.
        - Keep summary dry, concise, project-oriented.
        - Never hallucinate.
        - task_segments should represent semantic work units in this interval.
        - Each segment must include: task, issue_or_goal, actions, outcome, next_step, status, confidence, evidence_refs.
        - status must be one of: done, in_progress, pending, blocked.
        - confidence is 0..1.
        - evidence_refs should cite evidence IDs/timestamps from the provided list when possible.
        - Use empty strings or [] for unknown optional fields.
        """

        let userPrompt = """
        Bucket: \(iso8601(bucketStart)) - \(iso8601(bucketEnd))
        App: \(appName)
        Bundle: \(bundleID ?? "")
        Timeline slices:
        \(timelineLines.isEmpty ? "- none" : timelineLines)

        Artifact analyses:
        \(evidenceLines.isEmpty ? "- none" : evidenceLines)
        """

        let payload: [String: Any] = [
            "model": model,
            "reasoning": ["effort": reasoningEffort],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "interval_app_summary",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": [
                            "summary": ["type": "string"],
                            "entities": ["type": "array", "items": ["type": "string"]],
                            "insufficient_evidence": ["type": "boolean"],
                            "task_segments": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "task": ["type": "string"],
                                        "issue_or_goal": ["type": "string"],
                                        "actions": ["type": "array", "items": ["type": "string"]],
                                        "outcome": ["type": "string"],
                                        "next_step": ["type": "string"],
                                        "status": ["type": "string", "enum": ["done", "in_progress", "pending", "blocked"]],
                                        "confidence": ["type": "number"],
                                        "evidence_refs": ["type": "array", "items": ["type": "string"]],
                                        "project": ["type": "string"],
                                        "workspace": ["type": "string"],
                                        "repo": ["type": "string"],
                                        "document": ["type": "string"],
                                        "url": ["type": "string"],
                                        "app_name": ["type": "string"],
                                        "bundle_id": ["type": "string"],
                                        "entities": ["type": "array", "items": ["type": "string"]]
                                    ],
                                    "required": [
                                        "task", "issue_or_goal", "actions", "outcome", "next_step",
                                        "status", "confidence", "evidence_refs", "project", "workspace",
                                        "repo", "document", "url", "app_name", "bundle_id", "entities"
                                    ],
                                    "additionalProperties": false
                                ]
                            ]
                        ],
                        "required": ["summary", "entities", "insufficient_evidence", "task_segments"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ]
        ]

        return try call(
            payload: payload,
            model: model,
            kind: "synthesis_interval_app",
            apiKey: apiKey,
            timeoutSeconds: timeoutSeconds
        )
    }

    func synthesizeHour(
        hourStart: Date,
        hourEnd: Date,
        intervalSummaries: [IntervalSummary],
        timeline: [TimelineSlice],
        apiKey: String
    ) throws -> OpenRouterCallResult {
        let model = textModel
        let appSummaryLines = intervalSummaries.map {
            "- [\(iso8601($0.bucketStart)) \($0.appName)] \($0.summary)"
        }.joined(separator: "\n")

        let timelineLines = timeline.map { slice in
            "- \(iso8601(slice.startTime)) to \(iso8601(slice.endTime)): \(slice.appName)"
        }.joined(separator: "\n")

        let systemPrompt = """
        Produce a dry, specific hour-level report synthesis for work logging.
        Return strict JSON with keys: summary, entities, insufficient_evidence, task_segments.
        Rules:
        - Build from per-app interval summaries and timeline only.
        - Mention projects/workspaces only when evidence supports it.
        - If evidence is insufficient, explicitly use \"insufficient evidence\".
        - task_segments should summarize cross-app meaningful work outcomes for this hour.
        - Each segment must include: task, issue_or_goal, actions, outcome, next_step, status, confidence, evidence_refs.
        - status must be one of: done, in_progress, pending, blocked.
        - confidence is 0..1.
        """

        let userPrompt = """
        Hour: \(iso8601(hourStart)) - \(iso8601(hourEnd))

        Per-app interval summaries:
        \(appSummaryLines.isEmpty ? "- none" : appSummaryLines)

        Timeline:
        \(timelineLines.isEmpty ? "- none" : timelineLines)
        """

        let payload: [String: Any] = [
            "model": model,
            "reasoning": ["effort": reasoningEffort],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "hour_summary",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": [
                            "summary": ["type": "string"],
                            "entities": ["type": "array", "items": ["type": "string"]],
                            "insufficient_evidence": ["type": "boolean"],
                            "task_segments": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "task": ["type": "string"],
                                        "issue_or_goal": ["type": "string"],
                                        "actions": ["type": "array", "items": ["type": "string"]],
                                        "outcome": ["type": "string"],
                                        "next_step": ["type": "string"],
                                        "status": ["type": "string", "enum": ["done", "in_progress", "pending", "blocked"]],
                                        "confidence": ["type": "number"],
                                        "evidence_refs": ["type": "array", "items": ["type": "string"]],
                                        "project": ["type": "string"],
                                        "workspace": ["type": "string"],
                                        "repo": ["type": "string"],
                                        "document": ["type": "string"],
                                        "url": ["type": "string"],
                                        "app_name": ["type": "string"],
                                        "bundle_id": ["type": "string"],
                                        "entities": ["type": "array", "items": ["type": "string"]]
                                    ],
                                    "required": [
                                        "task", "issue_or_goal", "actions", "outcome", "next_step",
                                        "status", "confidence", "evidence_refs", "project", "workspace",
                                        "repo", "document", "url", "app_name", "bundle_id", "entities"
                                    ],
                                    "additionalProperties": false
                                ]
                            ]
                        ],
                        "required": ["summary", "entities", "insufficient_evidence", "task_segments"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ]
        ]

        return try call(
            payload: payload,
            model: model,
            kind: "synthesis_hour",
            apiKey: apiKey,
            timeoutSeconds: timeoutSeconds
        )
    }

    func planMemoryQuery(
        question: String,
        now: Date,
        detailLevel: MemoryQueryDetailLevel,
        timeZone: TimeZone,
        apiKey: String
    ) throws -> OpenRouterCallResult {
        let systemPrompt = """
        You generate compact retrieval plans for a life-log memory store.
        Return strict JSON only with keys: detail_level, steps, timeframe.
        Rules:
        - steps: 1-8 structured retrieval steps ordered by execution priority.
        - Each step must contain: query, phase, sources, max_results.
        - query must be short and retrieval-oriented (nouns/entities/actions), never answer-oriented.
        - phase must be either research or evidence.
        - sources must contain one or both of: bm25, mem0.
        - Use bm25 research steps when you need fast local reconnaissance before broader evidence retrieval.
        - Use evidence steps for the main retrieval pass.
        - If the question names a specific project/repo/person/entity, include that token verbatim in most step queries.
        - Keep user entities/nouns exactly as written when present.
        - Add aliases only when high-confidence and concise.
        - Avoid paraphrase explosion; do not output near-duplicate steps.
        - max_results should usually be between 3 and 12.
        - detail_level must be either concise or detailed.
        - Infer detail_level from user intent (detailed report/timeline/exhaustive requests => detailed).
        - timeframe must include start, end, label.
        - start/end: ISO8601 timestamp or empty string when not inferable.
        - label: short scope hint such as today/this week/last month, else empty string.
        - If user provides explicit dates (for example 2026-03-10 to 2026-03-14), preserve those exact day boundaries in timeframe.
        - Resolve relative dates using provided local time context and timezone.
        - For detailed/timeline/report requests, produce query variants that maximize evidence recall across the requested period.
        - If the question explicitly asks for dimensions or aspects (for example projects, blockers, people involved, decisions, fit), make sure the plan covers each requested dimension.
        - Keep the plan query-driven; do not rely on canned task-specific templates.
        - Never answer the user question here.
        """

        let userPrompt = """
        Current UTC time: \(iso8601(now))
        Current local time (\(timeZone.identifier)): \(localTimestamp(now, timeZone: timeZone))
        Current retrieval mode hint (you may override): \(detailLevel.rawValue)
        User question: \(question)
        """

        let payload: [String: Any] = [
            "model": queryAgentModel,
            "reasoning": ["effort": reasoningEffort],
            "temperature": 0.1,
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "memory_query_plan",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": [
                            "detail_level": [
                                "type": "string",
                                "enum": ["concise", "detailed"]
                            ],
                            "steps": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "query": ["type": "string"],
                                        "phase": [
                                            "type": "string",
                                            "enum": ["research", "evidence"]
                                        ],
                                        "sources": [
                                            "type": "array",
                                            "items": [
                                                "type": "string",
                                                "enum": ["bm25", "mem0"]
                                            ],
                                            "minItems": 1,
                                            "maxItems": 2
                                        ],
                                        "max_results": [
                                            "type": "integer",
                                            "minimum": 1,
                                            "maximum": 20
                                        ]
                                    ],
                                    "required": ["query", "phase", "sources", "max_results"],
                                    "additionalProperties": false
                                ],
                                "minItems": 1,
                                "maxItems": 8
                            ],
                            "timeframe": [
                                "type": "object",
                                "properties": [
                                    "start": ["type": "string"],
                                    "end": ["type": "string"],
                                    "label": ["type": "string"]
                                ],
                                "required": ["start", "end", "label"],
                                "additionalProperties": false
                            ]
                        ],
                        "required": ["detail_level", "steps", "timeframe"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ]
        ]

        return try callWithFallbackModels(
            payload: payload,
            models: preferredQueryModels(),
            kind: "memory_query_plan",
            apiKey: apiKey
        )
    }

    func answerMemoryQuery(
        question: String,
        scope: MemoryQueryScope,
        detailLevel: MemoryQueryDetailLevel,
        now: Date,
        timeZone: TimeZone,
        mem0EvidenceLines: [String],
        bm25EvidenceLines: [String],
        apiKey: String
    ) throws -> OpenRouterCallResult {
        let systemPrompt = """
        You answer memory questions using only retrieved evidence from two retrieval sources.
        Return strict JSON with keys: answer, key_points, supporting_events, insufficient_evidence.
        Rules:
        - Use only provided evidence; never invent facts.
        - There are two sources: MEM0_SEMANTIC and BM25_STORAGE.
        - Prefer facts that appear in both sources when possible.
        - If sources conflict, state the conflict explicitly and lower confidence.
        - Keep the answer focused on the entities/topics explicitly asked in the question; skip unrelated memories.
        - answer should directly address the user's question.
        - Infer the best answer structure from the question itself.
        - If the user explicitly names dimensions or aspects, address each of those dimensions directly.
        - Use short headings only when they mirror the user's requested dimensions or materially improve clarity.
        - Do not force canned task-specific templates.
        - If the user asks for an assessment, judgment, or opinion, provide a clearly provisional evidence-backed judgment instead of avoiding the question.
        - key_points: factual bullets.
        - supporting_events: short event lines with timestamps/apps when available.
        - If evidence is weak or missing for parts of the question, set insufficient_evidence=true and state limits.
        - Treat explicit dates as hard constraints.
        - If detail level is detailed: provide chronological, specific event breakdown and avoid hand-wavy summary language.
        - If detail level is detailed:
          - answer must start with a one-paragraph summary,
          - choose chronology or topical grouping based on what the user asked for,
          - include date/time ordered breakdown (oldest -> newest) when the question is timeline-oriented or asks for a date-window summary,
          - each timeline bullet should start with [YYYY-MM-DD HH:mm] when timestamp is present,
          - include concrete actions, changes, outcomes, and open follow-ups,
          - include concrete artifacts when present (files, commands, URLs, errors, PRs/issues, model names, settings keys),
          - avoid vague phrases like "worked on stuff" or "made progress",
          - key_points should usually be 8-30 items,
          - supporting_events should usually be 12-120 items when evidence exists.
        - If detail level is concise:
          - keep key_points around 3-8 and supporting_events around 4-16.
        - If requested scope is broad but evidence is sparse, be explicit about gaps by day or topic.
        """

        let scopeText = scope.label?.nilIfEmpty ?? "unspecified"
        let scopeStartText = scope.start.map(iso8601) ?? ""
        let scopeEndText = scope.end.map(iso8601) ?? ""
        let mem0Text = mem0EvidenceLines.isEmpty ? "- none" : mem0EvidenceLines.joined(separator: "\n")
        let bm25Text = bm25EvidenceLines.isEmpty ? "- none" : bm25EvidenceLines.joined(separator: "\n")
        let userPrompt = """
        Current UTC time: \(iso8601(now))
        Current local time (\(timeZone.identifier)): \(localTimestamp(now, timeZone: timeZone))
        Detail level: \(detailLevel.rawValue)
        Scope: \(scopeText)
        Scope start: \(scopeStartText)
        Scope end: \(scopeEndText)
        Question: \(question)

        MEM0_SEMANTIC evidence:
        \(mem0Text)

        BM25_STORAGE evidence:
        \(bm25Text)
        """

        let payload: [String: Any] = [
            "model": queryAgentModel,
            "reasoning": ["effort": reasoningEffort],
            "temperature": 0.1,
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "memory_query_answer",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": [
                            "answer": ["type": "string"],
                            "key_points": [
                                "type": "array",
                                "items": ["type": "string"]
                            ],
                            "supporting_events": [
                                "type": "array",
                                "items": ["type": "string"]
                            ],
                            "insufficient_evidence": ["type": "boolean"]
                        ],
                        "required": ["answer", "key_points", "supporting_events", "insufficient_evidence"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ]
        ]

        return try callWithFallbackModels(
            payload: payload,
            models: preferredQueryModels(),
            kind: "memory_query_answer",
            apiKey: apiKey
        )
    }

    private func preferredQueryModels() -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for model in [queryAgentModel, textModel] {
            guard seen.insert(model).inserted else { continue }
            ordered.append(model)
        }
        return ordered
    }

    private func callWithFallbackModels(
        payload: [String: Any],
        models: [String],
        kind: String,
        apiKey: String
    ) throws -> OpenRouterCallResult {
        var latestError: Error?
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        for model in models {
            var modelPayload = payload
            modelPayload["model"] = model
            let remainingTimeout = max(0.5, deadline.timeIntervalSinceNow)
            if remainingTimeout <= 0.5, latestError != nil {
                break
            }
            do {
                return try call(
                    payload: modelPayload,
                    model: model,
                    kind: kind,
                    apiKey: apiKey,
                    timeoutSeconds: remainingTimeout
                )
            } catch {
                latestError = error
            }
        }

        throw latestError ?? NSError(
            domain: "OpenRouterClient",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: "No model available for \(kind)"]
        )
    }

    private func call(
        payload: [String: Any],
        model: String,
        kind: String,
        apiKey: String,
        timeoutSeconds: TimeInterval
    ) throws -> OpenRouterCallResult {
        let body = try JSONSerialization.data(withJSONObject: payload, options: [])

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let appNameHeader, !appNameHeader.isEmpty {
            request.setValue(appNameHeader, forHTTPHeaderField: "X-Title")
        }
        if let refererHeader, !refererHeader.isEmpty {
            request.setValue(refererHeader, forHTTPHeaderField: "HTTP-Referer")
        }

        let semaphore = DispatchSemaphore(value: 0)
        let box = NetworkResponseBox()

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            box.set(data: data, error: error, statusCode: (response as? HTTPURLResponse)?.statusCode)
            semaphore.signal()
        }
        task.resume()

        let waitResult = semaphore.wait(timeout: .now() + timeoutSeconds + 1)
        if waitResult == .timedOut {
            task.cancel()
            throw NSError(
                domain: "OpenRouterClient",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Request timed out after \(String(format: "%.1f", timeoutSeconds))s"]
            )
        }

        let snapshot = box.snapshot()
        let responseData = snapshot.data
        let responseError = snapshot.error
        let statusCode = snapshot.statusCode

        if let responseError {
            throw responseError
        }

        guard let responseData else {
            throw NSError(domain: "OpenRouterClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "No response body from OpenRouter"])
        }

        guard (statusCode ?? 500) < 400 else {
            let bodyText = String(data: responseData, encoding: .utf8) ?? ""
            throw NSError(domain: "OpenRouterClient", code: statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: "OpenRouter error \(statusCode ?? 500): \(bodyText)"])
        }

        let raw = try JSONSerialization.jsonObject(with: responseData, options: [])
        guard let object = raw as? [String: Any] else {
            throw NSError(domain: "OpenRouterClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response shape"])
        }

        guard let messageText = extractMessageText(object) else {
            let bodyText = String(data: responseData, encoding: .utf8) ?? ""
            throw NSError(domain: "OpenRouterClient", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing completion text: \(bodyText)"])
        }

        let usageTuple = parseUsage(object)
        let usage = LLMUsageEvent(
            id: UUID().uuidString,
            kind: kind,
            createdAt: Date(),
            model: model,
            inputTokens: usageTuple.input,
            outputTokens: usageTuple.output,
            audioTokens: usageTuple.audio,
            estimatedCostUSD: estimateCost(input: usageTuple.input, output: usageTuple.output, audio: usageTuple.audio)
        )

        return OpenRouterCallResult(text: messageText, usage: usage)
    }

    private func extractMessageText(_ response: [String: Any]) -> String? {
        guard
            let choices = response["choices"] as? [[String: Any]],
            let firstChoice = choices.first,
            let message = firstChoice["message"] as? [String: Any]
        else {
            return nil
        }

        if let content = message["content"] as? String {
            return content
        }

        if let contentArray = message["content"] as? [[String: Any]] {
            let pieces = contentArray.compactMap { item -> String? in
                if let text = item["text"] as? String {
                    return text
                }
                return nil
            }
            return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
        }

        return nil
    }

    private func parseUsage(_ response: [String: Any]) -> (input: Int, output: Int, audio: Int) {
        guard let usage = response["usage"] as? [String: Any] else {
            return (0, 0, 0)
        }

        let input = usage["prompt_tokens"] as? Int ?? 0
        let output = usage["completion_tokens"] as? Int ?? 0

        var audioTokens = 0
        if let details = usage["prompt_tokens_details"] as? [String: Any] {
            audioTokens += details["audio_tokens"] as? Int ?? 0
        }
        if let details = usage["completion_tokens_details"] as? [String: Any] {
            audioTokens += details["audio_tokens"] as? Int ?? 0
        }

        return (input, output, audioTokens)
    }

    private func estimateCost(input: Int, output: Int, audio: Int) -> Double {
        let inputRate = 0.10 / 1_000_000.0
        let outputRate = 0.40 / 1_000_000.0
        let audioRate = 0.60 / 1_000_000.0
        return (Double(input) * inputRate) + (Double(output) * outputRate) + (Double(audio) * audioRate)
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func localTimestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"
        return formatter.string(from: date)
    }

    private func webPDataForLLM(from imagePath: String) throws -> Data {
        let url = URL(fileURLWithPath: imagePath)
        if url.pathExtension.lowercased() == "webp" {
            return try Data(contentsOf: url)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(
                domain: "OpenRouterClient",
                code: 101,
                userInfo: [NSLocalizedDescriptionKey: "Unable to decode screenshot for WebP conversion: \(imagePath)"]
            )
        }

        if let nativeWebP = encodeNativeWebP(image: image) {
            return nativeWebP
        }

        if let cwebpData = encodeWebPWithCWebP(image: image) {
            return cwebpData
        }

        throw NSError(
            domain: "OpenRouterClient",
            code: 102,
            userInfo: [NSLocalizedDescriptionKey: "Unable to convert screenshot to WebP for LLM: \(imagePath)"]
        )
    }

    private func encodeNativeWebP(image: CGImage) -> Data? {
        guard
            let mutableData = CFDataCreateMutable(nil, 0),
            let destination = CGImageDestinationCreateWithData(
                mutableData,
                UTType.webP.identifier as CFString,
                1,
                nil
            )
        else {
            return nil
        }

        let options = [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return mutableData as Data
    }

    private func encodeWebPWithCWebP(image: CGImage) -> Data? {
        guard let cwebpPath = Self.cwebpPath else { return nil }
        guard let pngData = encodePNG(image: image) else { return nil }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-context-or-webp-\(UUID().uuidString)", isDirectory: true)
        let inputURL = tempDirectory.appendingPathComponent("input.png")
        let outputURL = tempDirectory.appendingPathComponent("output.webp")

        do {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDirectory) }
            try pngData.write(to: inputURL, options: .atomic)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: cwebpPath)
            process.arguments = ["-quiet", "-q", "65", inputURL.path, "-o", outputURL.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return try Data(contentsOf: outputURL)
        } catch {
            return nil
        }
    }

    private func encodePNG(image: CGImage) -> Data? {
        guard
            let mutableData = CFDataCreateMutable(nil, 0),
            let destination = CGImageDestinationCreateWithData(
                mutableData,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    private static let cwebpPath: String? = {
        let candidates = [
            "/opt/homebrew/bin/cwebp",
            "/usr/local/bin/cwebp",
            "/usr/bin/cwebp"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()
}

func decodeArtifactAnalysis(
    from text: String,
    fallbackProject: String? = nil,
    fallbackWorkspace: String? = nil,
    fallbackTaskHint: String? = nil
) -> ArtifactAnalysis {
    if let object = parseArtifactJSON(text) {
        let transcript = objectString(object, keys: ["transcript"])
        var description = normalizeArtifactField(
            objectString(object, keys: ["description", "summary"])
        ) ?? "insufficient evidence"
        description = sanitizeSummaryPhrasing(description)

        var project = normalizeArtifactField(objectString(object, keys: ["project"])) ?? fallbackProject?.nilIfEmpty
        var workspace = normalizeArtifactField(objectString(object, keys: ["workspace"])) ?? fallbackWorkspace?.nilIfEmpty
        var task = normalizeTask(objectString(object, keys: ["task"]))
        let evidence = uniqueStrings(object["evidence"] as? [String] ?? [])
        var entities = uniqueStrings(object["entities"] as? [String] ?? [])
        var problem = normalizeArtifactField(objectString(object, keys: ["problem"]))
        var success = normalizeArtifactField(objectString(object, keys: ["success"]))
        let userContribution = normalizeArtifactField(objectString(object, keys: ["user_contribution", "userContribution"]))
        let suggestionOrDecision = normalizeArtifactField(
            objectString(object, keys: ["suggestion_or_decision", "suggestionOrDecision"])
        )
        let confidence = object["confidence"] == nil ? 0 : clampConfidence(object["confidence"])
        let insufficient = boolValue(object["insufficient_evidence"])
            ?? boolValue(object["insufficientEvidence"])
            ?? description.lowercased().contains("insufficient evidence")

        if confidence < highConfidenceInferenceThreshold {
            problem = nil
            success = nil
        }

        if insufficient {
            return ArtifactAnalysis(
                description: "insufficient evidence",
                problem: nil,
                success: nil,
                userContribution: nil,
                suggestionOrDecision: nil,
                status: .none,
                confidence: 0,
                summary: "insufficient evidence",
                transcript: transcript,
                entities: entities,
                insufficientEvidence: true,
                project: project,
                workspace: workspace,
                task: task,
                evidence: []
            )
        }

        let inferenceSeed = composeArtifactSummary(
            description: description,
            problem: problem,
            success: success,
            userContribution: userContribution,
            suggestionOrDecision: suggestionOrDecision,
            status: .none,
            insufficient: false
        )

        task = normalizeTask(task)
            ?? inferTask(summary: inferenceSeed, evidence: evidence, fallbackHint: fallbackTaskHint)

        if project == nil {
            project = inferProject(from: inferenceSeed, entities: entities)
        }
        if workspace == nil {
            workspace = inferWorkspace(from: inferenceSeed, entities: entities)
        }

        if let project, !entities.contains(project) {
            entities.append(project)
        }
        if let workspace, !entities.contains(workspace) {
            entities.append(workspace)
        }
        if let task, !entities.contains(task) {
            entities.append(task)
        }

        if description == "{" || description.count < 24 {
            description = fallbackSummary(project: project, workspace: workspace, task: task, evidence: evidence) ?? description
        }

        var status = parseArtifactInferenceStatus(object["status"])
        if status == .none {
            if problem != nil {
                status = .blocked
            } else if success != nil {
                status = .resolved
            } else if userContribution != nil || suggestionOrDecision != nil || task != nil {
                status = .inProgress
            }
        }

        var summary = composeArtifactSummary(
            description: description,
            problem: problem,
            success: success,
            userContribution: userContribution,
            suggestionOrDecision: suggestionOrDecision,
            status: status,
            insufficient: false
        )
        if let task, !summaryContainsTask(summary, task: task) {
            summary = "Working on \(task). \(summary)"
        }

        return ArtifactAnalysis(
            description: description,
            problem: problem,
            success: success,
            userContribution: userContribution,
            suggestionOrDecision: suggestionOrDecision,
            status: status,
            confidence: confidence,
            summary: summary,
            transcript: transcript,
            entities: entities,
            insufficientEvidence: false,
            project: project,
            workspace: workspace,
            task: task,
            evidence: evidence
        )
    }

    let fallback = cleanedFreeformText(text) ?? "insufficient evidence"
    let insufficient = fallback.lowercased().contains("insufficient evidence")
    let description = insufficient ? "insufficient evidence" : sanitizeSummaryPhrasing(fallback)
    let summary = composeArtifactSummary(
        description: description,
        problem: nil,
        success: nil,
        userContribution: nil,
        suggestionOrDecision: nil,
        status: .none,
        insufficient: insufficient
    )
    return ArtifactAnalysis(
        description: description,
        problem: nil,
        success: nil,
        userContribution: nil,
        suggestionOrDecision: nil,
        status: .none,
        confidence: 0,
        summary: summary,
        transcript: nil,
        entities: [],
        insufficientEvidence: insufficient,
        project: nil,
        workspace: nil,
        task: nil,
        evidence: []
    )
}

func decodeStructuredSynthesis(
    from text: String,
    defaultTask: String? = nil,
    defaultProject: String? = nil,
    defaultWorkspace: String? = nil,
    defaultAppName: String? = nil,
    defaultBundleID: String? = nil
) -> StructuredSynthesis {
    guard let object = parseArtifactJSON(text) else {
        let fallbackSummary = cleanedFreeformText(text) ?? "insufficient evidence"
        let insufficient = fallbackSummary.lowercased().contains("insufficient evidence")
        let fallbackSegment = fallbackTaskSegment(
            summary: fallbackSummary,
            defaultTask: defaultTask,
            defaultProject: defaultProject,
            defaultWorkspace: defaultWorkspace,
            defaultAppName: defaultAppName,
            defaultBundleID: defaultBundleID
        )
        return StructuredSynthesis(
            summary: fallbackSummary,
            entities: fallbackSegment.map { [$0.task] } ?? [],
            insufficientEvidence: insufficient,
            taskSegments: fallbackSegment.map { [$0] } ?? []
        )
    }

    let summary = (object["summary"] as? String)?.nilIfEmpty ?? "insufficient evidence"
    let insufficient = (object["insufficient_evidence"] as? Bool) ?? summary.lowercased().contains("insufficient evidence")
    var entities = uniqueStrings(object["entities"] as? [String] ?? [])

    var segments: [TaskSegmentDraft] = []
    if let rawSegments = object["task_segments"] as? [[String: Any]] {
        for raw in rawSegments {
            let task = normalizeTask((raw["task"] as? String)?.nilIfEmpty)
                ?? normalizeTask(defaultTask)
                ?? inferTask(summary: summary, evidence: raw["evidence_refs"] as? [String] ?? [], fallbackHint: nil)
                ?? "unknown task"

            let issueOrGoal = normalizeTask((raw["issue_or_goal"] as? String)?.nilIfEmpty)
            let actions = uniqueStrings(raw["actions"] as? [String] ?? [])
            let outcome = normalizeTask((raw["outcome"] as? String)?.nilIfEmpty)
            let nextStep = normalizeTask((raw["next_step"] as? String)?.nilIfEmpty)
            let status = parseTaskSegmentStatus((raw["status"] as? String), outcome: outcome, nextStep: nextStep)
            let confidence = clampConfidence(raw["confidence"])
            let evidenceRefs = uniqueStrings(raw["evidence_refs"] as? [String] ?? [])
            var segmentEntities = uniqueStrings(raw["entities"] as? [String] ?? [])
            let project = normalizeTask((raw["project"] as? String)?.nilIfEmpty) ?? normalizeTask(defaultProject)
            let workspace = normalizeTask((raw["workspace"] as? String)?.nilIfEmpty) ?? normalizeTask(defaultWorkspace)
            let repo = normalizeTask((raw["repo"] as? String)?.nilIfEmpty)
            let document = normalizeTask((raw["document"] as? String)?.nilIfEmpty)
            let url = normalizeTask((raw["url"] as? String)?.nilIfEmpty)
            let appName = normalizeTask((raw["app_name"] as? String)?.nilIfEmpty) ?? normalizeTask(defaultAppName)
            let bundleID = normalizeTask((raw["bundle_id"] as? String)?.nilIfEmpty) ?? normalizeTask(defaultBundleID)

            for marker in [task, issueOrGoal, project, workspace, repo, document] {
                if let marker, !segmentEntities.contains(marker) {
                    segmentEntities.append(marker)
                }
            }

            segments.append(
                TaskSegmentDraft(
                    task: task,
                    issueOrGoal: issueOrGoal,
                    actions: actions,
                    outcome: outcome,
                    nextStep: nextStep,
                    status: status,
                    confidence: confidence,
                    evidenceRefs: evidenceRefs,
                    entities: segmentEntities,
                    project: project,
                    workspace: workspace,
                    repo: repo,
                    document: document,
                    url: url,
                    appName: appName,
                    bundleID: bundleID
                )
            )
        }
    }

    if segments.isEmpty, !insufficient,
       let fallback = fallbackTaskSegment(
           summary: summary,
           defaultTask: defaultTask,
           defaultProject: defaultProject,
           defaultWorkspace: defaultWorkspace,
           defaultAppName: defaultAppName,
           defaultBundleID: defaultBundleID
       ) {
        segments = [fallback]
    }

    for segment in segments {
        if !entities.contains(segment.task) {
            entities.append(segment.task)
        }
        if let project = segment.project, !entities.contains(project) {
            entities.append(project)
        }
        if let workspace = segment.workspace, !entities.contains(workspace) {
            entities.append(workspace)
        }
    }

    return StructuredSynthesis(
        summary: summary,
        entities: entities,
        insufficientEvidence: insufficient,
        taskSegments: segments
    )
}

private let highConfidenceInferenceThreshold = 0.72

private func objectString(_ object: [String: Any], keys: [String]) -> String? {
    for key in keys {
        if let text = (object[key] as? String)?.nilIfEmpty {
            return text
        }
    }
    return nil
}

private func boolValue(_ raw: Any?) -> Bool? {
    if let value = raw as? Bool {
        return value
    }
    if let value = raw as? NSNumber {
        return value.boolValue
    }
    if let value = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        switch value {
        case "true", "1", "yes":
            return true
        case "false", "0", "no":
            return false
        default:
            return nil
        }
    }
    return nil
}

private func normalizeArtifactField(_ text: String?) -> String? {
    guard var value = text?.nilIfEmpty else { return nil }
    value = value
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    while value.contains("  ") {
        value = value.replacingOccurrences(of: "  ", with: " ")
    }
    if value == "{" || value == "}" {
        return nil
    }
    return value.nilIfEmpty
}

private func parseArtifactInferenceStatus(_ raw: Any?) -> ArtifactInferenceStatus {
    guard let value = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
        return .none
    }

    switch value {
    case "blocked", "stalled":
        return .blocked
    case "in_progress", "in progress", "active", "working", "ongoing":
        return .inProgress
    case "resolved", "done", "complete", "completed", "success":
        return .resolved
    default:
        return .none
    }
}

private func composeArtifactSummary(
    description: String,
    problem: String?,
    success: String?,
    userContribution: String?,
    suggestionOrDecision: String?,
    status: ArtifactInferenceStatus,
    insufficient: Bool
) -> String {
    if insufficient {
        return "insufficient evidence"
    }

    var parts: [String] = [ensureSentence(sanitizeSummaryPhrasing(description))]

    if let problem {
        parts.append("Problem: \(ensureSentence(problem))")
    }
    if let success {
        parts.append("Success: \(ensureSentence(success))")
    }
    if let userContribution {
        parts.append("User contribution: \(ensureSentence(userContribution))")
    }
    if let suggestionOrDecision {
        parts.append("Suggestion/decision: \(ensureSentence(suggestionOrDecision))")
    }
    if status != .none {
        parts.append("Status: \(artifactStatusLabel(status)).")
    }

    return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func artifactStatusLabel(_ status: ArtifactInferenceStatus) -> String {
    switch status {
    case .none:
        return "none"
    case .blocked:
        return "blocked"
    case .inProgress:
        return "in progress"
    case .resolved:
        return "resolved"
    }
}

private func ensureSentence(_ text: String) -> String {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let last = value.last else { return value }
    if [".", "!", "?"].contains(last) {
        return value
    }
    return "\(value)."
}

private func parseArtifactJSON(_ text: String) -> [String: Any]? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

    let candidates: [String] = [
        trimmed,
        stripMarkdownCodeFence(trimmed),
        firstJSONObjectString(in: trimmed) ?? "",
        firstJSONObjectString(in: stripMarkdownCodeFence(trimmed)) ?? ""
    ]

    for candidate in candidates where !candidate.isEmpty {
        guard let data = candidate.data(using: .utf8) else { continue }
        if let raw = try? JSONSerialization.jsonObject(with: data, options: []),
           let object = raw as? [String: Any] {
            return object
        }
    }

    return nil
}

private func stripMarkdownCodeFence(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("```") else {
        return trimmed
    }

    var lines = trimmed.components(separatedBy: .newlines)
    if !lines.isEmpty {
        lines.removeFirst()
    }

    while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
        lines.removeLast()
    }

    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func firstJSONObjectString(in text: String) -> String? {
    var startIndex: String.Index?
    var depth = 0
    var inString = false
    var escaping = false

    for index in text.indices {
        let character = text[index]

        if escaping {
            escaping = false
            continue
        }

        if inString {
            if character == "\\" {
                escaping = true
            } else if character == "\"" {
                inString = false
            }
            continue
        }

        if character == "\"" {
            inString = true
            continue
        }

        if character == "{" {
            if startIndex == nil {
                startIndex = index
            }
            depth += 1
            continue
        }

        if character == "}" && depth > 0 {
            depth -= 1
            if depth == 0, let startIndex {
                let end = text.index(after: index)
                return String(text[startIndex..<end])
            }
        }
    }

    return nil
}

private func fallbackSummary(
    project: String?,
    workspace: String?,
    task: String?,
    evidence: [String]
) -> String? {
    var fragments: [String] = []
    if let task {
        fragments.append(task)
    }
    if let project {
        fragments.append("project \(project)")
    }
    if let workspace {
        fragments.append("workspace \(workspace)")
    }
    if !evidence.isEmpty {
        fragments.append(evidence.prefix(2).joined(separator: "; "))
    }
    return fragments.joined(separator: " • ").nilIfEmpty
}

private func fallbackTaskSegment(
    summary: String,
    defaultTask: String?,
    defaultProject: String?,
    defaultWorkspace: String?,
    defaultAppName: String?,
    defaultBundleID: String?
) -> TaskSegmentDraft? {
    let task = normalizeTask(defaultTask)
        ?? inferTask(summary: summary, evidence: [], fallbackHint: nil)
        ?? normalizeTask(extractQuotedPhrase(from: summary))
    guard let task else { return nil }

    let status: TaskSegmentStatus = summary.lowercased().contains("insufficient evidence") ? .unknown : .inProgress
    return TaskSegmentDraft(
        task: task,
        issueOrGoal: nil,
        actions: [],
        outcome: nil,
        nextStep: nil,
        status: status,
        confidence: 0.45,
        evidenceRefs: [],
        entities: [task],
        project: normalizeTask(defaultProject),
        workspace: normalizeTask(defaultWorkspace),
        repo: nil,
        document: nil,
        url: nil,
        appName: normalizeTask(defaultAppName),
        bundleID: normalizeTask(defaultBundleID)
    )
}

private func parseTaskSegmentStatus(_ raw: String?, outcome: String?, nextStep: String?) -> TaskSegmentStatus {
    let normalized = raw?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

    switch normalized {
    case "done", "completed", "complete", "resolved":
        return .done
    case "in_progress", "in progress", "active", "working":
        return .inProgress
    case "pending", "todo", "to_do":
        return .pending
    case "blocked", "stalled":
        return .blocked
    default:
        break
    }

    if outcome?.nilIfEmpty != nil {
        return .done
    }
    if nextStep?.nilIfEmpty != nil {
        return .pending
    }
    return .inProgress
}

private func clampConfidence(_ raw: Any?) -> Double {
    if let value = raw as? Double {
        return max(0, min(1, value))
    }
    if let value = raw as? NSNumber {
        return max(0, min(1, value.doubleValue))
    }
    if let text = raw as? String, let value = Double(text) {
        return max(0, min(1, value))
    }
    return 0.55
}

private func normalizeTask(_ task: String?) -> String? {
    guard var value = task?.nilIfEmpty else { return nil }
    value = value
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))

    if value.count < 4 {
        return nil
    }

    let lowercased = value.lowercased()
    let generic = [
        "working in app",
        "using app",
        "general browsing",
        "unknown",
        "n/a"
    ]
    if generic.contains(where: { lowercased == $0 }) {
        return nil
    }

    return value
}

private func inferTask(summary: String, evidence: [String], fallbackHint: String?) -> String? {
    let candidates: [String?] = [
        extractQuotedPhrase(from: summary),
        extractWorkingOnPhrase(from: summary),
        fallbackHint,
        evidence.first
    ]

    for candidate in candidates {
        if let normalized = normalizeTask(candidate) {
            return normalized
        }
    }
    return nil
}

private func sanitizeSummaryPhrasing(_ summary: String) -> String {
    var output = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    let replacements: [(String, String)] = [
        ("The user is ", ""),
        ("The user ", ""),
        ("User is ", "")
    ]

    for (prefix, replacement) in replacements {
        if output.hasPrefix(prefix) {
            output = replacement + output.dropFirst(prefix.count)
            break
        }
    }

    if let first = output.first {
        output = String(first).uppercased() + output.dropFirst()
    }
    return output
}

private func inferProject(from summary: String, entities: [String]) -> String? {
    for entity in entities {
        let lowercased = entity.lowercased()
        if lowercased.contains("project") || lowercased.contains("workspace") {
            return entity
        }
    }

    let lower = summary.lowercased()
    if let range = lower.range(of: "project ") {
        let tail = String(lower[range.upperBound...])
        let value = tail.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first
        return normalizeTask(value.map(String.init))
    }
    return nil
}

private func inferWorkspace(from summary: String, entities: [String]) -> String? {
    for entity in entities {
        let lowercased = entity.lowercased()
        if lowercased.contains("workspace") || lowercased.contains("thread") {
            return entity
        }
    }

    let lower = summary.lowercased()
    if let range = lower.range(of: "workspace ") {
        let tail = String(lower[range.upperBound...])
        let value = tail.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first
        return normalizeTask(value.map(String.init))
    }
    return nil
}

private func extractQuotedPhrase(from text: String) -> String? {
    let components = text.components(separatedBy: "'")
    if components.count >= 3 {
        return components[1].nilIfEmpty
    }
    return nil
}

private func extractWorkingOnPhrase(from text: String) -> String? {
    let lower = text.lowercased()
    guard let range = lower.range(of: "working on ") else { return nil }
    let rawTail = String(text[range.upperBound...])
    let delimiterSet = CharacterSet(charactersIn: ".,;\n")
    if let delimiterRange = rawTail.rangeOfCharacter(from: delimiterSet) {
        return String(rawTail[..<delimiterRange.lowerBound]).nilIfEmpty
    }
    return rawTail.nilIfEmpty
}

private func summaryContainsTask(_ summary: String, task: String) -> Bool {
    let summaryLower = summary.lowercased()
    let taskLower = task.lowercased()
    return summaryLower.contains(taskLower)
}

private func cleanedFreeformText(_ text: String) -> String? {
    let cleaned = stripMarkdownCodeFence(text)
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = cleaned.nilIfEmpty else {
        return nil
    }
    if value == "{" || value == "}" {
        return "insufficient evidence"
    }
    return value
}

private func uniqueStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var output: [String] = []
    for value in values {
        guard let normalized = value.nilIfEmpty else { continue }
        if seen.insert(normalized).inserted {
            output.append(normalized)
        }
    }
    return output
}
