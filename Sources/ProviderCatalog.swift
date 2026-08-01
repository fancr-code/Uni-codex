import Foundation

struct ProviderCatalogStore: Codable, Equatable {
    let schemaVersion: Int
    var generatedAt: String
    var providers: [ProviderDefinition]

    static func load(from url: URL) throws -> Self {
        let store = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try store.validate()
        return store
    }

    func models(for provider: ProviderKind) -> [ModelDefinition] {
        providers.first(where: { $0.kind == provider })?.models ?? []
    }

    mutating func replaceModels(
        for provider: ProviderKind,
        with models: [ModelDefinition],
        generatedAt: String
    ) throws {
        guard let index = providers.firstIndex(where: { $0.kind == provider }) else {
            throw catalogError("provider is absent from the catalog")
        }
        let normalized = Self.normalize(models)
        guard !normalized.isEmpty else {
            throw catalogError("provider model list is empty")
        }
        providers[index] = ProviderDefinition(
            kind: providers[index].kind,
            protocolName: providers[index].protocolName,
            models: normalized
        )
        self.generatedAt = generatedAt
        try validate()
    }

    func writeAtomically(to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".model-catalog-\(UUID().uuidString).tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data) else {
            throw catalogError("unable to create temporary model catalog")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()

        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    private func validate() throws {
        guard schemaVersion == 1, !generatedAt.isEmpty else {
            throw catalogError("invalid model catalog metadata")
        }
        var kinds = Set<ProviderKind>()
        for provider in providers {
            guard kinds.insert(provider.kind).inserted else {
                throw catalogError("duplicate provider")
            }
            guard provider.protocolName == "chatCompletions", !provider.models.isEmpty else {
                throw catalogError("invalid provider definition")
            }
            let normalized = Self.normalize(provider.models)
            guard normalized.count == provider.models.count,
                  normalized.map(\.id) == provider.models.map(\.id) else {
                throw catalogError("provider models must be unique and sorted")
            }
            guard provider.models.allSatisfy({ model in
                !model.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !model.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && (model.contextWindow == nil || model.contextWindow! > 0)
            }) else {
                throw catalogError("invalid model definition")
            }
        }
    }

    private static func normalize(_ models: [ModelDefinition]) -> [ModelDefinition] {
        var byID: [String: ModelDefinition] = [:]
        for model in models {
            let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, byID[id] == nil else { continue }
            let displayName = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            byID[id] = ModelDefinition(
                id: id,
                displayName: displayName.isEmpty ? id : displayName,
                contextWindow: model.contextWindow
            )
        }
        return byID.values.sorted {
            $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
    }

    private func catalogError(_ message: String) -> NSError {
        NSError(
            domain: "CodexOneClickInstaller.ProviderCatalog",
            code: 65,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

protocol HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw NSError(domain: "CodexOneClickInstaller.HTTP", code: 65)
        }
        return (data, response)
    }
}

struct ProviderCatalogClient {
    let transport: any HTTPTransport

    func fetchModels(provider: ProviderKind, apiKey: String) async throws -> [ModelDefinition] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 8 else {
            throw clientError("invalid API Key")
        }
        var request = URLRequest(url: provider.modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport.data(for: request)
        guard response.statusCode == 200 else {
            throw clientError("upstream models request failed")
        }
        return try Self.normalizeModelsResponse(data)
    }

    static func normalizeModelsResponse(_ data: Data) throws -> [ModelDefinition] {
        struct Response: Decodable {
            struct Item: Decodable { let id: String }
            let data: [Item]
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        var seen = Set<String>()
        let models = response.data.compactMap { item -> ModelDefinition? in
            let id = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return ModelDefinition(id: id, displayName: id, contextWindow: nil)
        }.sorted {
            $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
        guard !models.isEmpty else {
            throw clientError("upstream returned no models")
        }
        return models
    }

    private static func clientError(_ message: String) -> NSError {
        NSError(
            domain: "CodexOneClickInstaller.ProviderCatalogClient",
            code: 65,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func clientError(_ message: String) -> NSError {
        Self.clientError(message)
    }
}
