import Foundation

// MARK: - Provider configuration

/// Points the client at any OpenAI-compatible server. Default = local Ollama.
/// Swap `baseURL`/`apiKey` later to use a hosted provider without touching
/// call sites.
struct ProviderConfig: Sendable {
    var baseURL: URL
    var apiKey: String
    var chatModel: String
    var embeddingModel: String

    static let ollama = ProviderConfig(
        baseURL: URL(string: "http://localhost:11434/v1")!,
        apiKey: "ollama", // required by the OpenAI shape, ignored by Ollama
        chatModel: "llama3.2",             // any chat model you have `ollama pull`-ed
        embeddingModel: "nomic-embed-text" // 768-dim; swap for bge-m3 / qwen3-embedding for stronger multilingual (e.g. Italian)
    )
}

// MARK: - Messages

struct ChatMessage: Codable, Sendable {
    enum Role: String, Codable, Sendable {
        case system, user, assistant
    }
    let role: Role
    let content: String

    init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }
}

// MARK: - Errors

enum LLMError: Error, LocalizedError {
    case emptyResponse
    case badResponse
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .emptyResponse: return "The model returned an empty response."
        case .badResponse:   return "Unexpected response from the server."
        case .http(let status, let body): return "HTTP \(status): \(body)"
        }
    }
}

// MARK: - Client

actor LLMService {
    private let config: ProviderConfig
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(config: ProviderConfig = .ollama, session: URLSession? = nil) {
        self.config = config
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 120
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: Chat

    /// Send a chat turn and return the assistant's text.
    /// Low temperature by default — most pipeline steps want consistent,
    /// parseable output rather than creativity.
    func chat(
        _ messages: [ChatMessage],
        temperature: Double = 0.2,
        model: String? = nil
    ) async throws -> String {
        struct Request: Encodable {
            let model: String
            let messages: [ChatMessage]
            let temperature: Double
            let stream: Bool
        }
        struct Response: Decodable {
            struct Choice: Decodable { let message: ChatMessage }
            let choices: [Choice]
        }

        let body = Request(
            model: model ?? config.chatModel,
            messages: messages,
            temperature: temperature,
            stream: false
        )
        let data = try await post("chat/completions", body: body)
        let decoded = try decoder.decode(Response.self, from: data)
        guard let text = decoded.choices.first?.message.content else {
            throw LLMError.emptyResponse
        }
        return text
    }

    // MARK: Embeddings

    /// Embed a single string into a vector for similarity comparison.
    func embed(_ input: String, model: String? = nil) async throws -> [Double] {
        struct Request: Encodable {
            let model: String
            let input: String
        }
        struct Response: Decodable {
            struct Item: Decodable { let embedding: [Double] }
            let data: [Item]
        }

        let body = Request(model: model ?? config.embeddingModel, input: input)
        let data = try await post("embeddings", body: body)
        let decoded = try decoder.decode(Response.self, from: data)
        guard let vector = decoded.data.first?.embedding else {
            throw LLMError.emptyResponse
        }
        return vector
    }

    // MARK: Transport

    private func post<Body: Encodable>(_ path: String, body: Body) async throws -> Data {
        let url = config.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(status: http.statusCode,
                                body: String(data: data, encoding: .utf8) ?? "<no body>")
        }
        return data
    }
}

// MARK: - Vector math

/// Cosine similarity in [-1, 1]. The organizer uses this to find a new todo's
/// nearest neighbours before handing the short candidate list to the LLM.
func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot = 0.0, normA = 0.0, normB = 0.0
    for i in a.indices {
        dot   += a[i] * b[i]
        normA += a[i] * a[i]
        normB += b[i] * b[i]
    }
    let denom = (normA.squareRoot() * normB.squareRoot())
    return denom == 0 ? 0 : dot / denom
}
