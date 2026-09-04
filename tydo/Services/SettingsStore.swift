import Foundation
import Observation

/// One configurable provider endpoint. Tydo has three, so chat, embedding and
/// reasoning can each point at a different OpenAI-compatible server — the
/// combination that matters is a hosted chat model with embeddings still
/// running locally, since OpenRouter and Groq expose no /embeddings at all.
enum ProviderSlot: String, CaseIterable, Sendable {
    case chat, embedding, reasoning
    var keychainAccount: String { "\(rawValue).apiKey" }
}

/// UserDefaults-backed provider settings, surfaced in the Settings tab.
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    var baseURL: String        { didSet { defaults.set(baseURL, forKey: Keys.baseURL) } }
    var chatModel: String      { didSet { defaults.set(chatModel, forKey: Keys.chatModel) } }
    var embeddingModel: String { didSet { defaults.set(embeddingModel, forKey: Keys.embeddingModel) } }

    /// Empty means "same server as chat", which is what a pure-local setup wants.
    var embeddingBaseURL: String { didSet { defaults.set(embeddingBaseURL, forKey: Keys.embeddingBaseURL) } }

    /// Separate, swappable model for the Mastermind planner.
    var reasoningBaseURL: String   { didSet { defaults.set(reasoningBaseURL, forKey: Keys.reasoningBaseURL) } }
    var reasoningChatModel: String { didSet { defaults.set(reasoningChatModel, forKey: Keys.reasoningChatModel) } }

    /// How many days a *completed* todo survives before maintenance deletes it.
    var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: Keys.retentionDays) } }

    // The app and standalone CLI are separate processes, so use one explicit domain.
    private let defaults: UserDefaults
    private let keychainService: String
    private enum Keys {
        static let baseURL = "provider.baseURL"
        static let chatModel = "provider.chatModel"
        static let embeddingModel = "provider.embeddingModel"
        static let embeddingBaseURL = "provider.embeddingBaseURL"
        static let reasoningBaseURL = "reasoning.baseURL"
        static let reasoningChatModel = "reasoning.chatModel"
        static let retentionDays = "maintenance.retentionDays"
    }

    private init() {
        let suffix = ProcessInfo.processInfo.environment["TYDO_DATA_DIR"].map {
            Data($0.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        } ?? ""
        defaults = UserDefaults(suiteName: suffix.isEmpty ? "it.clait.tydo" : "it.clait.tydo.test.\(suffix)")!
        // ponytail: the service string still says "reasoning" because renaming it
        // would orphan every existing Keychain item. It holds all three slots now.
        keychainService = suffix.isEmpty ? "it.clait.tydo.reasoning" : "it.clait.tydo.reasoning.test.\(suffix)"
        let d = ProviderConfig.ollama
        baseURL          = defaults.string(forKey: Keys.baseURL) ?? d.baseURL.absoluteString
        chatModel        = defaults.string(forKey: Keys.chatModel) ?? d.chatModel
        embeddingModel   = defaults.string(forKey: Keys.embeddingModel) ?? d.embeddingModel
        embeddingBaseURL = defaults.string(forKey: Keys.embeddingBaseURL) ?? ""
        reasoningBaseURL   = defaults.string(forKey: Keys.reasoningBaseURL) ?? d.baseURL.absoluteString
        reasoningChatModel = defaults.string(forKey: Keys.reasoningChatModel) ?? d.chatModel
        retentionDays  = defaults.object(forKey: Keys.retentionDays) != nil
            ? defaults.integer(forKey: Keys.retentionDays) : 30
    }

    // MARK: - Keys

    /// Local servers ignore the value but the OpenAI shape requires the header.
    func apiKey(_ slot: ProviderSlot) throws -> String {
        try KeychainStore.read(service: keychainService, account: slot.keychainAccount)
            ?? ProviderConfig.ollama.apiKey
    }

    func hasAPIKey(_ slot: ProviderSlot) throws -> Bool {
        try KeychainStore.read(service: keychainService, account: slot.keychainAccount) != nil
    }

    func setAPIKey(_ value: String?, for slot: ProviderSlot) throws {
        if let value { try KeychainStore.write(value, service: keychainService, account: slot.keychainAccount) }
        else { try KeychainStore.delete(service: keychainService, account: slot.keychainAccount) }
    }

    // MARK: - Resolved configurations

    private func url(_ string: String) -> URL {
        URL(string: string) ?? ProviderConfig.ollama.baseURL
    }

    /// The server a slot actually talks to. An empty embedding URL means "same
    /// server as chat", so a local-only setup needs no second configuration.
    func resolvedBaseURL(_ slot: ProviderSlot) -> String {
        switch slot {
        case .chat: return baseURL
        case .embedding: return embeddingBaseURL.isEmpty ? baseURL : embeddingBaseURL
        case .reasoning: return reasoningBaseURL
        }
    }

    /// Chat: grammar cleanup, enrichment, grouping decisions, document extraction.
    func chatProviderConfig() throws -> ProviderConfig {
        ProviderConfig(
            baseURL: url(baseURL),
            apiKey: try apiKey(.chat),
            chatModel: chatModel,
            embeddingModel: embeddingModel
        )
    }

    /// Embeddings, which can stay on localhost even when chat does not.
    func embeddingProviderConfig() throws -> ProviderConfig {
        ProviderConfig(
            baseURL: url(resolvedBaseURL(.embedding)),
            apiKey: try apiKey(embeddingBaseURL.isEmpty ? .chat : .embedding),
            chatModel: chatModel,
            embeddingModel: embeddingModel
        )
    }

    /// The Mastermind's reasoning model, independent of the other two.
    func reasoningProviderConfig() throws -> ProviderConfig {
        ProviderConfig(
            baseURL: url(reasoningBaseURL),
            apiKey: try apiKey(.reasoning),
            chatModel: reasoningChatModel,
            embeddingModel: embeddingModel
        )
    }
}
