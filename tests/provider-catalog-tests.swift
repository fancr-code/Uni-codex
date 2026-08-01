import Foundation

func providerRequire(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw NSError(
            domain: "ProviderCatalogTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

func providerRequireThrows(_ message: String, _ operation: () throws -> Void) throws {
    do {
        try operation()
        throw NSError(domain: "ProviderCatalogTests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    } catch let error as NSError where error.domain == "ProviderCatalogTests" && error.code == 2 {
        throw error
    } catch {
        return
    }
}

func providerRequireAsyncThrows(_ message: String, _ operation: () async throws -> Void) async throws {
    do {
        try await operation()
        throw NSError(domain: "ProviderCatalogTests", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    } catch let error as NSError where error.domain == "ProviderCatalogTests" && error.code == 3 {
        throw error
    } catch {
        return
    }
}

final class RecordingTransport: HTTPTransport {
    var responseData: Data
    var statusCode: Int
    private(set) var lastRequest: URLRequest?

    init(responseData: Data, statusCode: Int = 200) {
        self.responseData = responseData
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (responseData, response)
    }
}

@main
struct ProviderCatalogTests {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "ProviderCatalogTests", code: 64)
        }
        let catalogURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = try ProviderCatalogStore.load(from: catalogURL)

        try providerRequire(store.schemaVersion == 1, "catalog schema")
        try providerRequire(
            store.models(for: .deepSeek).map(\.id) == ["deepseek-v4-flash", "deepseek-v4-pro"],
            "DeepSeek snapshot"
        )
        try providerRequire(
            store.models(for: .kimiOpen).map(\.id) == [
                "kimi-k2.6",
                "kimi-k2.7-code",
                "kimi-k2.7-code-highspeed",
                "kimi-k3"
            ],
            "Kimi Open snapshot"
        )
        try providerRequire(
            store.models(for: .kimiCode).map(\.id) == ["k3", "kimi-for-coding", "kimi-for-coding-highspeed"],
            "Kimi Code snapshot"
        )
        try providerRequire(
            store.models(for: .zhipu).map(\.id) == [
                "glm-4-flash-250414", "glm-4-flashx-250414", "glm-4.5-air",
                "glm-4.5-airx", "glm-4.5-flash", "glm-4.6", "glm-4.7",
                "glm-4.7-flash", "glm-4.7-flashx", "glm-5", "glm-5-turbo",
                "glm-5.1", "glm-5.2"
            ],
            "Zhipu snapshot sorted"
        )
        try providerRequire(
            store.models(for: .qwen).map(\.id) == [
                "qwen3.7-flash", "qwen3.7-max", "qwen3.7-plus"
            ],
            "Qwen snapshot sorted"
        )
        try providerRequire(
            store.models(for: .qwen).allSatisfy { $0.contextWindow == 1_000_000 },
            "Qwen context windows"
        )
        try providerRequire(
            store.models(for: .xiaomiMiMo).map(\.id) == ["mimo-v2.5", "mimo-v2.5-pro"]
                && store.models(for: .xiaomiMiMo).allSatisfy { $0.contextWindow == 1_000_000 },
            "Xiaomi MiMo snapshot and context windows"
        )
        try providerRequire(
            !store.models(for: .xiaomiMiMo).contains { ["mimo-v2-pro", "mimo-v2-omni", "mimo-v2-flash"].contains($0.id) },
            "retired Xiaomi models excluded"
        )

        var updated = store
        try updated.replaceModels(
            for: .deepSeek,
            with: [
                ModelDefinition(id: "z-model", displayName: "z-model", contextWindow: nil),
                ModelDefinition(id: "a-model", displayName: "a-model", contextWindow: nil),
                ModelDefinition(id: "a-model", displayName: "duplicate", contextWindow: nil)
            ],
            generatedAt: "2026-07-21T01:02:03Z"
        )
        try providerRequire(updated.models(for: .deepSeek).map(\.id) == ["a-model", "z-model"], "replacement normalized")
        try providerRequire(updated.models(for: .kimiCode) == store.models(for: .kimiCode), "other provider unchanged")

        let normalizedBody = #"{"data":[{"id":"model-b"},{"id":"model-a"},{"id":"model-a"}]}"#.data(using: .utf8)!
        let normalized = try ProviderCatalogClient.normalizeModelsResponse(normalizedBody)
        try providerRequire(normalized.map(\.id) == ["model-a", "model-b"], "live response normalized")
        try providerRequireThrows("invalid live response rejected") {
            _ = try ProviderCatalogClient.normalizeModelsResponse(Data(#"{"models":[]}"#.utf8))
        }

        let transport = RecordingTransport(responseData: normalizedBody)
        let client = ProviderCatalogClient(transport: transport)
        let fetched = try await client.fetchModels(provider: .kimiCode, apiKey: "sk-in-memory-only")
        try providerRequire(fetched.map(\.id) == ["model-a", "model-b"], "client returns models")
        try providerRequire(
            transport.lastRequest?.url == ProviderKind.kimiCode.modelsURL,
            "provider models URL"
        )
        try providerRequire(
            transport.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-in-memory-only",
            "Bearer header set in request"
        )

        transport.statusCode = 503
        try await providerRequireAsyncThrows("non-200 rejected") {
            _ = try await client.fetchModels(provider: .deepSeek, apiKey: "sk-in-memory-only")
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-catalog-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let writtenURL = temporaryDirectory.appendingPathComponent("model-catalog.json")
        try updated.writeAtomically(to: writtenURL)
        let roundTrip = try ProviderCatalogStore.load(from: writtenURL)
        try providerRequire(roundTrip == updated, "atomic catalog round trip")

        print("provider-catalog-tests: PASS")
    }
}
