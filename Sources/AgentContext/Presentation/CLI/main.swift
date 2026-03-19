import Foundation
import AppKit

do {
    let rootAction = RootCLICommand.parse(arguments: CommandLine.arguments)
    switch rootAction {
    case .help:
        print(RootCLICommand.helpText(programName: "agent-context"))
        exit(0)
    case .version:
        print(RootCLICommand.versionText())
        exit(0)
    case .run:
        break
    }

    if let settingsOptions = try SettingsCLICommand.parse(arguments: CommandLine.arguments) {
        runSettingsMode(settingsOptions)
    } else if let options = try EvaluationCLICommand.parse(arguments: CommandLine.arguments) {
        runEvaluationMode(options)
    } else if let options = try QueryCLICommand.parse(arguments: CommandLine.arguments) {
        runQueryMode(options)
    } else if CommandLine.arguments.contains("--cli") {
        runCLIMode()
    } else {
        AgentContextMenuBarApp.run()
    }
} catch {
    fputs("fatal: \(error.localizedDescription)\n", stderr)
    exit(1)
}

private func runCLIMode() {
    do {
        let runtime = try TrackerRuntime()
        print("agent-context (vNext) CLI mode")
        for line in runtime.startupMessages() {
            print(line)
        }

        runtime.startRecording()
        print("Recording started. Press Ctrl+C to stop.")

        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue.main)
        source.setEventHandler {
            runtime.stopRecording(finalizePendingWork: true)
            exit(0)
        }
        source.resume()

        dispatchMain()
    } catch {
        fputs("fatal: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

private func runQueryMode(_ options: QueryCLIOptions) {
    do {
        let runtime = try TrackerRuntime()
        let group = DispatchGroup()
        group.enter()
        Task {
            let progressReporter: @Sendable (String) -> Void = { message in
                guard let data = "[agent-context] \(message)\n".data(using: .utf8) else { return }
                FileHandle.standardError.write(data)
            }
            let result = await runtime.runMemoryQuery(
                options.query,
                format: options.outputFormat,
                options: options.requestOptions,
                onProgress: progressReporter
            )
            print(result)
            group.leave()
        }
        group.wait()
    } catch {
        fputs("fatal: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

private func runEvaluationMode(_ options: EvaluationCLIOptions) {
    do {
        let runtime = try TrackerRuntime()
        let group = DispatchGroup()
        group.enter()
        Task {
            let progressReporter: @Sendable (String) -> Void = { message in
                guard let data = "[agent-context] \(message)\n".data(using: .utf8) else { return }
                FileHandle.standardError.write(data)
            }
            let result = await runtime.evaluateMemoryQuery(
                options.query,
                format: options.outputFormat,
                options: options.requestOptions,
                onProgress: progressReporter
            )
            print(result)
            group.leave()
        }
        group.wait()
    } catch {
        fputs("fatal: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

private func runSettingsMode(_ options: SettingsCLIOptions) {
    do {
        let runtime = try TrackerRuntime()
        let message = try SettingsCLICommand.run(runtime: runtime, options: options)
        print(message)
    } catch {
        fputs("fatal: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

private enum RootCLIAction {
    case help
    case version
    case run
}

private enum RootCLICommand {
    static func parse(arguments: [String]) -> RootCLIAction {
        guard arguments.count > 1 else {
            return .run
        }

        let first = arguments[1].lowercased()
        if first == "-h" || first == "--help" || first == "help" {
            return .help
        }
        if first == "--version" || first == "version" {
            return .version
        }
        return .run
    }

    static func helpText(programName: String) -> String {
        """
        Usage:
          \(programName) [--cli]
          \(programName) query "<question>" [--json|--format text|json] [--source all|mem0|bm25] [--start YYYY-MM-DD] [--end YYYY-MM-DD] [--max-results N] [--timeout SECONDS|none]
          \(programName) evaluate-query "<question>" [--json|--format text|json] [--source all|mem0|bm25] [--start YYYY-MM-DD] [--end YYYY-MM-DD] [--max-results N] [--timeout SECONDS|none]
          \(programName) --query "<question>" [--format text|json] [--source all|mem0|bm25] [--start YYYY-MM-DD] [--end YYYY-MM-DD] [--max-results N] [--timeout SECONDS|none]
          \(programName) --set-user-aliases "<alias1,alias2,...>"
          \(programName) --help
          \(programName) --version

        Notes:
          - Run without flags to open the Agent Context menu bar app.
          - Query commands return natural-language memory answers and stream progress to stderr.
          - evaluate-query runs the query first, then asks Gemini Flash Lite to score retrieval quality and answer groundedness.
        """
    }

    static func versionText() -> String {
        return "agent-context 0.1.0"
    }
}
