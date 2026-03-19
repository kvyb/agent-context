import Foundation

struct EvaluationCLIOptions: Sendable {
    let query: String
    let outputFormat: MemoryQueryOutputFormat
    let requestOptions: MemoryQueryOptions
}

enum EvaluationCLICommand {
    static func parse(arguments: [String]) throws -> EvaluationCLIOptions? {
        guard arguments.count > 1 else {
            return nil
        }

        let subcommand = arguments[1].lowercased()
        guard subcommand == "evaluate-query" || subcommand == "eval-query" else {
            return nil
        }

        var normalized = arguments
        normalized[1] = "query"
        guard let queryOptions = try QueryCLICommand.parse(arguments: normalized) else {
            return nil
        }

        return EvaluationCLIOptions(
            query: queryOptions.query,
            outputFormat: queryOptions.outputFormat,
            requestOptions: queryOptions.requestOptions
        )
    }

    static func run(runtime: TrackerRuntime, options: EvaluationCLIOptions) async -> String {
        await runtime.evaluateMemoryQuery(
            options.query,
            format: options.outputFormat,
            options: options.requestOptions
        )
    }
}
