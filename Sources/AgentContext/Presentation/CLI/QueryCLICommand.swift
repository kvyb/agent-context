import Foundation

enum QueryCLIArgumentError: Error, LocalizedError {
    case missingQueryValue
    case invalidFormat(String)
    case invalidSource(String)
    case invalidInteger(flag: String, value: String)
    case invalidNumber(flag: String, value: String)
    case invalidDate(flag: String, value: String)
    case invalidDateRange

    var errorDescription: String? {
        switch self {
        case .missingQueryValue:
            return "missing value for --query"
        case .invalidFormat(let raw):
            return "invalid --format value '\(raw)'; expected text or json"
        case .invalidSource(let raw):
            return "invalid --source value '\(raw)'; expected all, mem0, bm25, or a comma-separated combination"
        case let .invalidInteger(flag, value):
            return "invalid \(flag) value '\(value)'; expected a positive integer"
        case let .invalidNumber(flag, value):
            return "invalid \(flag) value '\(value)'; expected a positive number"
        case let .invalidDate(flag, value):
            return "invalid \(flag) value '\(value)'; expected YYYY-MM-DD or ISO8601"
        case .invalidDateRange:
            return "--end must be later than --start"
        }
    }
}

struct QueryCLIOptions: Sendable {
    let query: String
    let outputFormat: MemoryQueryOutputFormat
    let requestOptions: MemoryQueryOptions
}

enum QueryCLICommand {
    static func parse(arguments: [String]) throws -> QueryCLIOptions? {
        if arguments.count > 1, arguments[1].lowercased() == "query" {
            return try parseSubcommand(arguments: arguments)
        }

        guard let queryIndex = arguments.firstIndex(of: "--query") else {
            return nil
        }
        let queryValueIndex = arguments.index(after: queryIndex)
        guard queryValueIndex < arguments.count,
              let query = arguments[queryValueIndex].trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else {
            throw QueryCLIArgumentError.missingQueryValue
        }

        let formatRaw = argumentValue(flag: "--format", in: arguments) ?? MemoryQueryOutputFormat.text.rawValue
        guard let outputFormat = MemoryQueryOutputFormat(rawValue: formatRaw.lowercased()) else {
            throw QueryCLIArgumentError.invalidFormat(formatRaw)
        }

        return QueryCLIOptions(
            query: query,
            outputFormat: outputFormat,
            requestOptions: try parseRequestOptions(from: arguments)
        )
    }

    static func run(runtime: TrackerRuntime, options: QueryCLIOptions) async -> String {
        await runtime.runMemoryQuery(
            options.query,
            format: options.outputFormat,
            options: options.requestOptions
        )
    }

    private static func argumentValue(flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.count else {
            return nil
        }
        return arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func parseSubcommand(arguments: [String]) throws -> QueryCLIOptions {
        let tail = Array(arguments.dropFirst(2))

        let query = argumentValue(flag: "--query", in: tail)
            ?? argumentValue(flag: "--question", in: tail)
            ?? firstPositionalValue(in: tail)
        guard let query else {
            throw QueryCLIArgumentError.missingQueryValue
        }

        let formatRaw: String
        if tail.contains("--json") {
            formatRaw = MemoryQueryOutputFormat.json.rawValue
        } else {
            formatRaw = argumentValue(flag: "--format", in: tail) ?? MemoryQueryOutputFormat.text.rawValue
        }

        guard let outputFormat = MemoryQueryOutputFormat(rawValue: formatRaw.lowercased()) else {
            throw QueryCLIArgumentError.invalidFormat(formatRaw)
        }

        return QueryCLIOptions(
            query: query,
            outputFormat: outputFormat,
            requestOptions: try parseRequestOptions(from: tail)
        )
    }

    private static func firstPositionalValue(in arguments: [String]) -> String? {
        var skipNext = false
        for arg in arguments {
            if skipNext {
                skipNext = false
                continue
            }
            if [
                "--query",
                "--question",
                "--format",
                "--source",
                "--start",
                "--end",
                "--max-results",
                "--timeout"
            ].contains(arg) {
                skipNext = true
                continue
            }
            if arg.hasPrefix("--") {
                continue
            }
            return arg.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        return nil
    }

    private static func parseRequestOptions(from arguments: [String]) throws -> MemoryQueryOptions {
        let sources = try parseSources(raw: argumentValue(flag: "--source", in: arguments))
        let parsedStart = try parseDateArgument(
            flag: "--start",
            value: argumentValue(flag: "--start", in: arguments),
            treatDateOnlyAsEndExclusive: false
        )
        let parsedEnd = try parseDateArgument(
            flag: "--end",
            value: argumentValue(flag: "--end", in: arguments),
            treatDateOnlyAsEndExclusive: true
        )
        if let start = parsedStart, let end = parsedEnd, end <= start {
            throw QueryCLIArgumentError.invalidDateRange
        }

        let maxResults: Int?
        if let raw = argumentValue(flag: "--max-results", in: arguments) {
            guard let parsed = Int(raw), parsed > 0 else {
                throw QueryCLIArgumentError.invalidInteger(flag: "--max-results", value: raw)
            }
            maxResults = min(parsed, 200)
        } else {
            maxResults = nil
        }

        let timeoutSeconds: TimeInterval?
        if let raw = argumentValue(flag: "--timeout", in: arguments) {
            guard let parsed = Double(raw), parsed > 0 else {
                throw QueryCLIArgumentError.invalidNumber(flag: "--timeout", value: raw)
            }
            timeoutSeconds = min(parsed, 30)
        } else {
            timeoutSeconds = nil
        }

        return MemoryQueryOptions(
            sources: sources,
            scopeOverride: customScope(start: parsedStart, end: parsedEnd),
            maxResults: maxResults,
            timeoutSeconds: timeoutSeconds
        )
    }

    private static func parseSources(raw: String?) throws -> Set<MemoryEvidenceSource> {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return Set(MemoryEvidenceSource.allCases)
        }

        let lowered = raw.lowercased()
        if lowered == "all" {
            return Set(MemoryEvidenceSource.allCases)
        }

        var output = Set<MemoryEvidenceSource>()
        for token in lowered.split(separator: ",").map(String.init) {
            switch token.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "mem0", "semantic", "mem0_semantic":
                output.insert(.mem0Semantic)
            case "bm25", "lexical", "bm25_store":
                output.insert(.bm25Store)
            default:
                throw QueryCLIArgumentError.invalidSource(raw)
            }
        }

        guard !output.isEmpty else {
            throw QueryCLIArgumentError.invalidSource(raw)
        }
        return output
    }

    private static func parseDateArgument(
        flag: String,
        value: String?,
        treatDateOnlyAsEndExclusive: Bool
    ) throws -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }

        if let parsed = parseISO8601Date(value) {
            return parsed
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: value) else {
            throw QueryCLIArgumentError.invalidDate(flag: flag, value: value)
        }

        if treatDateOnlyAsEndExclusive {
            return Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: day)
        }
        return day
    }

    private static func parseISO8601Date(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: raw) {
            return parsed
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func customScope(start: Date?, end: Date?) -> MemoryQueryScope? {
        guard start != nil || end != nil else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"

        let label: String
        switch (start, end) {
        case let (start?, end?):
            let inclusiveEnd = end.addingTimeInterval(-1)
            label = "from \(formatter.string(from: start)) to \(formatter.string(from: inclusiveEnd))"
        case let (start?, nil):
            label = "since \(formatter.string(from: start))"
        case let (nil, end?):
            let inclusiveEnd = end.addingTimeInterval(-1)
            label = "until \(formatter.string(from: inclusiveEnd))"
        case (nil, nil):
            label = "custom range"
        }

        return MemoryQueryScope(start: start, end: end, label: label)
    }
}
