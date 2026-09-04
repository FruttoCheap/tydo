import Foundation
import Observation

struct TydoTodo: Codable, Identifiable, Sendable {
    let id: UUID
    let rawText: String
    let title: String
    let body: String?
    let status: String
    let stage: String
    let createdAt: Date
    let completedAt: Date?
    let groupID: UUID?
    let groupName: String?
}

struct TydoGroup: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let isGeneral: Bool
    let createdByAI: Bool
    let createdAt: Date
    let activeCount: Int
    let completedCount: Int
}

struct TydoClarification: Codable, Identifiable, Sendable {
    let id: UUID
    let todoID: UUID
    let todoTitle: String
    let optionGroupNames: [String]
    let createdAt: Date
    let wasPresented: Bool
}

struct TydoSnapshot: Codable, Sendable {
    let todos: [TydoTodo]
    let groups: [TydoGroup]
    let clarifications: [TydoClarification]

    static let empty = TydoSnapshot(todos: [], groups: [], clarifications: [])
}

struct TydoConfig: Codable, Sendable {
    let baseURL: String
    let chatModel: String
    let embeddingModel: String
    let reasoningBaseURL: String
    let reasoningChatModel: String
    let reasoningAPIKeyConfigured: Bool
    let retentionDays: Int
}

struct TydoMastermindProposal: Codable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let body: String?
    let rationale: String
    let group: String
}

struct TydoMastermindResult: Codable, Sendable {
    let summary: String
    let proposals: [TydoMastermindProposal]
}

private struct CLIEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
    let version: Int
    let data: Value
}

private struct CLIErrorEnvelope: Decodable {
    let error: String
}

private struct CLIMutation: Decodable, Sendable {
    let id: UUID
    let action: String
}

private struct CLIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
@Observable
final class TydoCLIClient {
    static let shared = TydoCLIClient()

    private let executableURL: URL
    private(set) var snapshot = TydoSnapshot.empty
    private(set) var config: TydoConfig?

    init(executableURL: URL? = nil) {
        if let executableURL {
            self.executableURL = executableURL
        } else if let path = ProcessInfo.processInfo.environment["TYDO_CLI_PATH"] {
            self.executableURL = URL(fileURLWithPath: path)
        } else {
            self.executableURL = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/tydo")
        }
    }

    func refresh() async throws {
        snapshot = try await call(["snapshot"])
    }

    func add(_ text: String) async throws {
        let _: TydoTodo = try await call(["todo", "add", text])
        try await refresh()
    }

    func addMany(_ items: [String]) async throws {
        let json = String(data: try JSONEncoder().encode(items), encoding: .utf8)!
        let _: [TydoTodo] = try await call(["todo", "add-many", json])
        try await refresh()
    }

    func rename(todo id: UUID, to title: String) async throws {
        let _: TydoTodo = try await call(["todo", "rename", id.uuidString, title])
        try await refresh()
    }

    func complete(todo id: UUID) async throws {
        let _: TydoTodo = try await call(["todo", "complete", id.uuidString])
        try await refresh()
    }

    func reopen(todo id: UUID) async throws {
        let _: TydoTodo = try await call(["todo", "reopen", id.uuidString])
        try await refresh()
    }

    func move(todo id: UUID, to groupID: UUID) async throws {
        let _: TydoTodo = try await call(["todo", "move", id.uuidString, groupID.uuidString])
        try await refresh()
    }

    func unassign(todo id: UUID) async throws {
        let _: TydoTodo = try await call(["todo", "unassign", id.uuidString])
        try await refresh()
    }

    func delete(todo id: UUID) async throws {
        let _: CLIMutation = try await call(["todo", "delete", id.uuidString, "--yes"])
        try await refresh()
    }

    func createGroup(named name: String) async throws {
        let _: TydoGroup = try await call(["group", "create", name])
        try await refresh()
    }

    func rename(group id: UUID, to name: String) async throws {
        let _: TydoGroup = try await call(["group", "rename", id.uuidString, name])
        try await refresh()
    }

    func delete(group id: UUID) async throws {
        let _: CLIMutation = try await call(["group", "delete", id.uuidString, "--yes"])
        try await refresh()
    }

    func markPresented(_ id: UUID) async throws {
        let _: TydoClarification = try await call(["clarification", "mark-presented", id.uuidString])
        try await refresh()
    }

    func resolve(_ id: UUID, choosing groupName: String) async throws {
        let _: CLIMutation = try await call(["clarification", "resolve", id.uuidString, groupName])
        try await refresh()
    }

    func extractDocument(at url: URL) async throws -> [String] {
        try await call(["document", "extract", url.path])
    }

    func extractText(_ text: String) async throws -> [String] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tydo-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await extractDocument(at: url)
    }

    func process() async throws {
        do {
            snapshot = try await call(["process"])
        } catch {
            try? await refresh()
            throw error
        }
    }

    func runMaintenance() async throws {
        snapshot = try await call(["maintenance"])
    }

    func analyze(groupID: UUID?) async throws -> TydoMastermindResult {
        var arguments = ["mastermind", "analyze"]
        if let groupID { arguments.append(groupID.uuidString) }
        return try await call(arguments)
    }

    func accept(_ proposal: TydoMastermindProposal) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(data: try encoder.encode(proposal), encoding: .utf8)!
        let _: TydoTodo = try await call(["mastermind", "accept", json])
        try await refresh()
    }

    func loadConfig() async throws {
        config = try await call(["config", "get"])
    }

    func updateConfig(
        baseURL: String,
        chatModel: String,
        embeddingModel: String,
        reasoningBaseURL: String,
        reasoningChatModel: String,
        reasoningAPIKey: String?,
        retentionDays: Int
    ) async throws {
        var update: [String: Any] = [
            "baseURL": baseURL,
            "chatModel": chatModel,
            "embeddingModel": embeddingModel,
            "reasoningBaseURL": reasoningBaseURL,
            "reasoningChatModel": reasoningChatModel,
            "retentionDays": retentionDays
        ]
        if let reasoningAPIKey, !reasoningAPIKey.isEmpty { update["reasoningAPIKey"] = reasoningAPIKey }
        config = try await call(
            ["config", "update"],
            input: try JSONSerialization.data(withJSONObject: update)
        )
    }

    private func call<Value: Decodable & Sendable>(_ arguments: [String], input: Data? = nil) async throws -> Value {
        let executableURL = executableURL
        let data = try await Task.detached {
            try Self.execute(executableURL, arguments: arguments, input: input)
        }.value
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(CLIEnvelope<Value>.self, from: data)
        guard envelope.version == 1 else {
            throw CLIError(message: "The bundled Tydo CLI uses an unsupported protocol version.")
        }
        return envelope.data
    }

    nonisolated private static func execute(_ executableURL: URL, arguments: [String], input: Data?) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CLIError(message: "Tydo CLI is missing at \(executableURL.path). Rebuild the app.")
        }

        let temporary = FileManager.default.temporaryDirectory
        let token = UUID().uuidString
        let outputURL = temporary.appendingPathComponent("tydo-\(token).out")
        let errorURL = temporary.appendingPathComponent("tydo-\(token).err")
        let inputURL = temporary.appendingPathComponent("tydo-\(token).in")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        if let input { try input.write(to: inputURL) }
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
            try? FileManager.default.removeItem(at: inputURL)
        }

        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer {
            try? output.close()
            try? errors.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let inputHandle = input == nil ? nil : try FileHandle(forReadingFrom: inputURL)
        process.standardInput = inputHandle
        process.standardOutput = output
        process.standardError = errors
        defer { try? inputHandle?.close() }
        try process.run()
        process.waitUntilExit()
        try output.synchronize()
        try errors.synchronize()

        if process.terminationStatus != 0 {
            let data = try Data(contentsOf: errorURL)
            if let response = try? JSONDecoder().decode(CLIErrorEnvelope.self, from: data) {
                throw CLIError(message: response.error)
            }
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError(message: message?.isEmpty == false ? message! : "Tydo CLI failed.")
        }
        return try Data(contentsOf: outputURL)
    }
}
