import Foundation
import Observation

/// UserDefaults-backed provider settings, surfaced in the Settings tab.
/// Exposed now but NOT called anywhere — the AI pipeline will read
/// `providerConfig` in a later phase.
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    var baseURL: String        { didSet { defaults.set(baseURL, forKey: Keys.baseURL) } }
    var chatModel: String      { didSet { defaults.set(chatModel, forKey: Keys.chatModel) } }
    var embeddingModel: String { didSet { defaults.set(embeddingModel, forKey: Keys.embeddingModel) } }

    /// Separate, swappable model for the Mastermind planner. Defaults to the
    /// same local Ollama setup; point it at a hosted provider later by
    /// changing these three fields only — LLMService itself doesn't change.
    var reasoningBaseURL: String   { didSet { defaults.set(reasoningBaseURL, forKey: Keys.reasoningBaseURL) } }
    var reasoningChatModel: String { didSet { defaults.set(reasoningChatModel, forKey: Keys.reasoningChatModel) } }

    /// How many days a todo survives before maintenance deletes it.
    var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: Keys.retentionDays) } }

    // The app and standalone CLI are separate processes, so use one explicit domain.
    private let defaults: UserDefaults
    private let keychainService: String
    private enum Keys {
        static let baseURL = "provider.baseURL"
        static let chatModel = "provider.chatModel"
        static let embeddingModel = "provider.embeddingModel"
        static let reasoningBaseURL = "reasoning.baseURL"
        static let reasoningChatModel = "reasoning.chatModel"
        static let reasoningAPIKey = "reasoning.apiKey"
        static let retentionDays = "maintenance.retentionDays"
    }

    private init() {
        let suffix = ProcessInfo.processInfo.environment["TYDO_DATA_DIR"].map {
            Data($0.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        } ?? ""
        defaults = UserDefaults(suiteName: suffix.isEmpty ? "it.clait.tydo" : "it.clait.tydo.test.\(suffix)")!
        keychainService = suffix.isEmpty ? "it.clait.tydo.reasoning" : "it.clait.tydo.reasoning.test.\(suffix)"
        let d = ProviderConfig.ollama
        baseURL        = defaults.string(forKey: Keys.baseURL) ?? d.baseURL.absoluteString
        chatModel      = defaults.string(forKey: Keys.chatModel) ?? d.chatModel
        embeddingModel = defaults.string(forKey: Keys.embeddingModel) ?? d.embeddingModel
        reasoningBaseURL   = defaults.string(forKey: Keys.reasoningBaseURL) ?? d.baseURL.absoluteString
        reasoningChatModel = defaults.string(forKey: Keys.reasoningChatModel) ?? d.chatModel
        retentionDays  = defaults.object(forKey: Keys.retentionDays) != nil
            ? defaults.integer(forKey: Keys.retentionDays) : 30
    }

    func readReasoningAPIKey() throws -> String {
        try KeychainStore.read(service: keychainService, account: Keys.reasoningAPIKey)
            ?? ProviderConfig.ollama.apiKey
    }

    func hasReasoningAPIKey() throws -> Bool {
        try KeychainStore.read(service: keychainService, account: Keys.reasoningAPIKey) != nil
    }

    func setReasoningAPIKey(_ value: String?) throws {
        if let value { try KeychainStore.write(value, service: keychainService, account: Keys.reasoningAPIKey) }
        else { try KeychainStore.delete(service: keychainService, account: Keys.reasoningAPIKey) }
    }

    // The AppDelegate builds the app's single LLMService from this at launch.
    var providerConfig: ProviderConfig {
        ProviderConfig(
            baseURL: URL(string: baseURL) ?? ProviderConfig.ollama.baseURL,
            apiKey: ProviderConfig.ollama.apiKey,
            chatModel: chatModel,
            embeddingModel: embeddingModel
        )
    }

    /// The Mastermind's reasoning model, independent of `providerConfig`.
    /// `embeddingModel` here is never used — Mastermind always embeds through
    /// the shared embeddingLLM built from `providerConfig` instead.
    func reasoningProviderConfig() throws -> ProviderConfig {
        ProviderConfig(
            baseURL: URL(string: reasoningBaseURL) ?? ProviderConfig.ollama.baseURL,
            apiKey: try readReasoningAPIKey(),
            chatModel: reasoningChatModel,
            embeddingModel: ProviderConfig.ollama.embeddingModel
        )
    }
}
