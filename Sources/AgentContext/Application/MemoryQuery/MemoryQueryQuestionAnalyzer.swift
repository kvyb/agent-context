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
        let mentionsZoom = lowered.contains("zoom")
        let prefersLexicalFirst = MemoryQueryQuestionLexicon.transcriptLikeTerms.contains { lowered.contains($0) }
        let seeksCallConversation = MemoryQueryQuestionLexicon.callConversationTerms.contains { lowered.contains($0) }
            || ((lowered.contains("call") || lowered.contains("zoom")) && (lowered.contains("talk") || lowered.contains("discuss")))
        let seeksEvaluation = MemoryQueryQuestionLexicon.evaluationTerms.contains { lowered.contains($0) }
        let seeksWorkSummary = MemoryQueryQuestionLexicon.workSummaryTerms.contains { lowered.contains($0) }
        let prefersDetailedAnswer = scopeParser.hasExplicitDate(in: question)
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
