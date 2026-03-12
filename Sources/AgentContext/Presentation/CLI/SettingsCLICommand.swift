import Foundation

enum SettingsCLIArgumentError: Error, LocalizedError {
    case missingUserAliasesValue
    case emptyUserAliasesValue

    var errorDescription: String? {
        switch self {
        case .missingUserAliasesValue:
            return "missing value for --set-user-aliases"
        case .emptyUserAliasesValue:
            return "no aliases provided; pass a comma-separated list such as \"Jane Doe, @jane\""
        }
    }
}

struct SettingsCLIOptions: Sendable {
    let userIdentityAliases: [String]
}

enum SettingsCLICommand {
    static func parse(arguments: [String]) throws -> SettingsCLIOptions? {
        guard let flagIndex = arguments.firstIndex(of: "--set-user-aliases") else {
            return nil
        }
        let valueIndex = arguments.index(after: flagIndex)
        guard valueIndex < arguments.count else {
            throw SettingsCLIArgumentError.missingUserAliasesValue
        }

        let aliases = AppSettings.parseAliases(from: arguments[valueIndex])
        guard !aliases.isEmpty else {
            throw SettingsCLIArgumentError.emptyUserAliasesValue
        }
        return SettingsCLIOptions(userIdentityAliases: aliases)
    }

    static func run(runtime: TrackerRuntime, options: SettingsCLIOptions) throws -> String {
        var settings = runtime.loadSettings()
        settings.userIdentityAliases = options.userIdentityAliases
        try runtime.saveSettings(settings)
        return "Saved user identity aliases: \(AppSettings.aliasesText(options.userIdentityAliases))"
    }
}
