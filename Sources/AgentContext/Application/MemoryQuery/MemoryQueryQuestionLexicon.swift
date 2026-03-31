import Foundation

enum MemoryQueryQuestionLexicon {
    static let transcriptLikeTerms = [
        "transcript", "interview", "meeting", "zoom", "call", "candidate", "notetaker"
    ]

    static let callConversationTerms = [
        "what did we talk",
        "what we talked",
        "what did we discuss",
        "what did we say",
        "on the zoom call",
        "on the call",
        "during the call",
        "during the zoom",
        "on zoom",
        "zoom call"
    ]

    static let evaluationTerms = [
        "how well",
        "fit",
        "match",
        "level",
        "assessment",
        "assess",
        "opinion",
        "suggest about",
        "suitability",
        "compare"
    ]

    static let workSummaryTerms = [
        "what did user do",
        "what did i do",
        "what happened in",
        "worked on",
        "for work",
        "work on",
        "tasks",
        "projects",
        "blockers",
        "takeaways",
        "struggles"
    ]

    static let detailedTerms = [
        "timeline",
        "everything",
        "comprehensive",
        "summarize",
        "summary",
        "breakdown",
        "report",
        "details"
    ]

    static let dimensionCuePrefixes = [
        "what are the ",
        "what were the ",
        "include ",
        "including ",
        "focus on ",
        "cover ",
        "covering ",
        "summarize ",
        "summarise ",
        "broken down by ",
        "grouped by ",
        "suggest about "
    ]

    static let genericFocusTerms: Set<String> = [
        "summary", "summarize", "summarise", "include", "including", "focus", "cover",
        "projects", "project", "tasks", "task", "takeaways", "takeaway", "struggles",
        "struggle", "blockers", "blocker", "questions", "answered", "strengths",
        "weaknesses", "fit", "bugs", "decisions", "issues", "people", "involved",
        "next", "steps", "technical", "topics", "discussed", "open", "follow", "actions",
        "well", "candidate", "engineer", "level", "intermediate", "senior", "junior", "match"
    ]

    static let dimensionNormalizationPrefixes = [
        "the ",
        "main ",
        "my ",
        "user ",
        "about ",
        "on ",
        "with ",
        "for "
    ]

    static let dimensionNormalizationSuffixes = [
        " from the transcript",
        " in the transcript",
        " in ai core work",
        " in open tulpa work",
        " in opentulpa work",
        " in manychat work"
    ]

    static let ignoredDimensions: Set<String> = [
        "what",
        "that",
        "this",
        "it",
        "call",
        "request",
        "requested",
        "does"
    ]

    static let personStopwords: Set<String> = [
        "about", "regarding", "on", "for", "during", "around", "and", "or", "the", "a", "an",
        "what", "how", "did", "we", "talk", "discuss", "zoom", "call", "meeting"
    ]
}
