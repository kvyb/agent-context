import Foundation
import AppKit

do {
    if let settingsOptions = try SettingsCLICommand.parse(arguments: CommandLine.arguments) {
        runSettingsMode(settingsOptions)
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
            let result = await QueryCLICommand.run(runtime: runtime, options: options)
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
