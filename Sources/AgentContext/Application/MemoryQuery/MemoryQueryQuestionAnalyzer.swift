import Foundation

struct MemoryQueryQuestionAnalysis: Sendable {
    let focusTerms: [String]
    let personTerms: [String]
    let requestedDimensions: [String]
    let mentionsZoom: Bool
    let seeksEvaluation: Bool
    let seeksWorkSummary: Bool
    let seeksCallConversation: Bool
    let prefersLexicalFirst: Bool
    let prefersDetailedAnswer: Bool
}

struct MemoryQueryQuestionAnalyzer: Sendable {
    private let scopeParser: MemoryQueryScopeParser
    private let extractionSupport: MemoryQueryQuestionExtractionSupport

    init(scopeParser: MemoryQueryScopeParser) {
        self.scopeParser = scopeParser
        self.extractionSupport = MemoryQueryQuestionExtractionSupport(scopeParser: scopeParser)
    }

    func analyze(question: String) -> MemoryQueryQuestionAnalysis {
        let lowered = question.lowercased()
        let requestedDimensions = extractionSupport.requestedDimensions(for: question)
        let focusTerms = extractionSupport.focusTerms(for: question, requestedDimensions: requestedDimensions)
        let personTerms = extractionSupport.personTerms(for: question)
        let inferredScope = scopeParser.inferScope(for: question)
        let mentionsZoom = lowered.contains("zoom")
        let prefersLexicalFirst = MemoryQueryQuestionLexicon.transcriptLikeTerms.contains { lowered.contains($0) }
        let mentionsCallMedium = lowered.contains("call")
            || lowered.contains("calls")
            || lowered.contains("meeting")
            || lowered.contains("meetings")
            || mentionsZoom
        let asksAboutConversationContent = lowered.contains("talk")
            || lowered.contains("discuss")
            || lowered.contains("say")
            || lowered.contains("happened")
            || lowered.contains("happen")
        let asksWhichCallsHappened = (lowered.contains("what") || lowered.contains("which"))
            && mentionsCallMedium
            && (lowered.contains(" did i have") || lowered.contains(" did we have") || lowered.contains(" had "))
        let seeksCallConversation = MemoryQueryQuestionLexicon.callConversationTerms.contains { lowered.contains($0) }
            || (mentionsCallMedium && asksAboutConversationContent)
            || asksWhichCallsHappened
        let seeksEvaluation = MemoryQueryQuestionLexicon.evaluationTerms.contains { lowered.contains($0) }
        let seeksWorkSummary = MemoryQueryQuestionLexicon.workSummaryTerms.contains { lowered.contains($0) }
        let hasBroadRelativeScope = {
            guard let start = inferredScope.start, let end = inferredScope.end else { return false }
            return end.timeIntervalSince(start) >= 36 * 3600
        }()
        let prefersDetailedAnswer = scopeParser.hasExplicitDate(in: question)
            || hasBroadRelativeScope
            || !requestedDimensions.isEmpty
            || MemoryQueryQuestionLexicon.detailedTerms.contains { lowered.contains($0) }

        return MemoryQueryQuestionAnalysis(
            focusTerms: focusTerms,
            personTerms: personTerms,
            requestedDimensions: requestedDimensions,
            mentionsZoom: mentionsZoom,
            seeksEvaluation: seeksEvaluation,
            seeksWorkSummary: seeksWorkSummary,
            seeksCallConversation: seeksCallConversation,
            prefersLexicalFirst: prefersLexicalFirst,
            prefersDetailedAnswer: prefersDetailedAnswer
        )
    }
}
