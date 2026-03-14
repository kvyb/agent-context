import Foundation

enum QueryCLIArgumentError: Error, LocalizedError {
    case missingQueryValue
    case invalidFormat(String)

    var errorDescription: String? {
        switch self {
        case .missingQueryValue:
            return "missing value for --query"
        case .invalidFormat(let raw):
            return "invalid --format value '\(raw)'; expected text or json"
        }
    }
}

struct QueryCLIOptions: Sendable {
    let query: String
    let outputFormat: MemoryQueryOutputFormat
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

        return QueryCLIOptions(query: query, outputFormat: outputFormat)
    }

    static func run(runtime: TrackerRuntime, options: QueryCLIOptions) async -> String {
        await runtime.runMemoryQuery(options.query, format: options.outputFormat)
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

        return QueryCLIOptions(query: query, outputFormat: outputFormat)
    }

    private static func firstPositionalValue(in arguments: [String]) -> String? {
        var skipNext = false
        for arg in arguments {
            if skipNext {
                skipNext = false
                continue
            }
            if arg == "--query" || arg == "--question" || arg == "--format" {
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
}
