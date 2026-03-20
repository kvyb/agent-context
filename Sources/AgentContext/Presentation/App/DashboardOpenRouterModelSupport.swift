import Foundation

struct DashboardOpenRouterModelSupport: Sendable {
    func withSelectedModels(
        _ models: [OpenRouterModelOption],
        selectedIDs: [String]
    ) -> [OpenRouterModelOption] {
        var byID = [String: OpenRouterModelOption]()
        for model in models {
            byID[model.id] = model
        }

        for selected in selectedIDs where byID[selected] == nil {
            byID[selected] = OpenRouterModelOption(id: selected, name: nil, inputModalities: [])
        }

        return byID.values.sorted { lhs, rhs in
            lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }
    }

    func selectedModelIDs(from settings: AppSettings) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        let candidates = [
            AppSettings.normalizedOpenRouterModel(settings.openRouterModel),
            AppSettings.normalizedOpenRouterModel(settings.openRouterAudioModel),
            AppSettings.normalizedOpenRouterModel(settings.openRouterTextModel)
        ]
        for candidate in candidates {
            guard seen.insert(candidate).inserted else { continue }
            output.append(candidate)
        }
        return output
    }

    func fetchOpenRouterModels(
        endpoint: URL,
        apiKey: String?,
        appNameHeader: String?,
        refererHeader: String?
    ) async throws -> [OpenRouterModelOption] {
        let modelsURL = modelsURL(from: endpoint)
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let appNameHeader, !appNameHeader.isEmpty {
            request.setValue(appNameHeader, forHTTPHeaderField: "X-Title")
        }
        if let refererHeader, !refererHeader.isEmpty {
            request.setValue(refererHeader, forHTTPHeaderField: "HTTP-Referer")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500
        guard statusCode < 400 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "OpenRouterModels",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Model list request failed (\(statusCode)): \(body)"]
            )
        }

        let decoded = try JSONDecoder().decode(OpenRouterModelListResponse.self, from: data)
        let options = decoded.data.compactMap { model -> OpenRouterModelOption? in
            guard let modelID = model.id.nilIfEmpty else { return nil }
            let modalities = normalizedInputModalities(from: model.architecture)
            return OpenRouterModelOption(
                id: modelID,
                name: model.name?.nilIfEmpty,
                inputModalities: Array(modalities)
            )
        }
        if options.isEmpty {
            throw NSError(
                domain: "OpenRouterModels",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No models returned from \(modelsURL.absoluteString)."]
            )
        }

        return options.sorted { lhs, rhs in
            lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }
    }

    private func normalizedInputModalities(from architecture: OpenRouterModelArchitecture?) -> Set<String> {
        var output = Set<String>()
        for modality in architecture?.inputModalities ?? [] {
            if let normalized = modality.nilIfEmpty?.lowercased() {
                output.insert(normalized)
            }
        }

        if output.isEmpty, let modality = architecture?.modality?.lowercased() {
            let inputPart = modality.components(separatedBy: "->").first ?? modality
            let components = inputPart
                .split(separator: "+")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            for component in components where !component.isEmpty {
                output.insert(component)
            }
        }

        return output
    }

    private func modelsURL(from endpoint: URL) -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint
        }

        var path = components.path
        if path.hasSuffix("/chat/completions") {
            path.removeLast("/chat/completions".count)
        } else if path.hasSuffix("/completions") {
            path.removeLast("/completions".count)
        } else if path.hasSuffix("/") {
            path.removeLast()
        } else if let slash = path.lastIndex(of: "/"), slash > path.startIndex {
            path = String(path[..<slash])
        } else {
            path = ""
        }

        let normalizedPrefix = path.hasSuffix("/") ? path : path + "/"
        components.path = normalizedPrefix + "models"
        components.queryItems = [URLQueryItem(name: "output_modality", value: "all")]
        components.fragment = nil
        return components.url ?? endpoint
    }
}

private struct OpenRouterModelListResponse: Decodable {
    let data: [OpenRouterModel]
}

private struct OpenRouterModel: Decodable {
    let id: String
    let name: String?
    let architecture: OpenRouterModelArchitecture?
}

private struct OpenRouterModelArchitecture: Decodable {
    let modality: String?
    let inputModalities: [String]?

    private enum CodingKeys: String, CodingKey {
        case modality
        case inputModalities = "input_modalities"
    }
}
