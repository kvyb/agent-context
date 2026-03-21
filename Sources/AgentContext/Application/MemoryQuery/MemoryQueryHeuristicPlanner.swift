import Foundation

struct QueryIntentProfile: Sendable {
    let prefersLexicalFirst: Bool
    let prefersDetailedAnswer: Bool
    let requestedDimensions: [String]
    let personTerms: [String]
    let mentionsZoom: Bool
    let seeksEvaluation: Bool
    let seeksCallConversation: Bool
    let seeksWorkSummary: Bool
    let focusTerms: [String]

    init(analysis: MemoryQueryQuestionAnalysis) {
        self.prefersLexicalFirst = analysis.prefersLexicalFirst
        self.prefersDetailedAnswer = analysis.prefersDetailedAnswer
        self.requestedDimensions = analysis.requestedDimensions
        self.personTerms = analysis.personTerms
        self.mentionsZoom = analysis.mentionsZoom
        self.seeksEvaluation = analysis.seeksEvaluation
        self.seeksCallConversation = analysis.seeksCallConversation
        self.seeksWorkSummary = analysis.seeksWorkSummary
        self.focusTerms = analysis.focusTerms
    }
}

struct MemoryQueryHeuristicPlanner: Sendable {
    private let questionAnalyzer: MemoryQueryQuestionAnalyzer
    private let queryBuilder: MemoryQueryHeuristicQueryBuilder

    init(scopeParser: MemoryQueryScopeParser) {
        self.questionAnalyzer = MemoryQueryQuestionAnalyzer(scopeParser: scopeParser)
        self.queryBuilder = MemoryQueryHeuristicQueryBuilder(scopeParser: scopeParser)
    }

    func profile(for question: String) -> QueryIntentProfile {
        QueryIntentProfile(analysis: questionAnalyzer.analyze(question: question))
    }

    func fallbackPlanResult(
        for question: String,
        fallbackScope: MemoryQueryScope,
        detailLevel: MemoryQueryDetailLevel,
        requestOptions: MemoryQueryOptions
    ) -> MemoryQueryPlanResult? {
        let queryProfile = profile(for: question)
        let steps = defaultPlanSteps(
            for: question,
            requestOptions: requestOptions,
            profile: queryProfile
        )
        guard !steps.isEmpty else {
            return nil
        }

        return MemoryQueryPlanResult(
            plan: MemoryQueryPlan(
                steps: steps,
                scope: fallbackScope,
                detailLevel: queryProfile.prefersDetailedAnswer ? .detailed : detailLevel
            ),
            usage: nil
        )
    }

    func defaultPlanSteps(
        for question: String,
        requestOptions: MemoryQueryOptions,
        profile: QueryIntentProfile
    ) -> [MemoryQueryPlanStep] {
        queryBuilder.defaultPlanSteps(
            for: question,
            requestOptions: requestOptions,
            profile: profile
        )
    }
}
