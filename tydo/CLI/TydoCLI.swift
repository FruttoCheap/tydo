import Darwin
import Foundation
import SwiftData

private let cliProtocolVersion = 1

private struct Envelope<Value: Encodable>: Encodable {
    let version = cliProtocolVersion
    let data: Value
}

private struct ErrorEnvelope: Encodable {
    let version = cliProtocolVersion
    let code: String
    let error: String
}

private struct VersionOutput: Encodable {
    let cli = "1.1.0"
    let protocolVersion = cliProtocolVersion
}

private struct MutationOutput: Encodable {
    let id: UUID
    let action: String
}

private struct TodoOutput: Encodable {
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

    init(_ todo: Todo) {
        id = todo.id
        rawText = todo.rawText
        title = todo.title
        body = todo.body
        status = todo.status.rawValue
        stage = todo.stage.rawValue
        createdAt = todo.createdAt
        completedAt = todo.completedAt
        groupID = todo.group?.id
        groupName = todo.group?.name
    }
}

private struct GroupOutput: Encodable {
    let id: UUID
    let name: String
    let isGeneral: Bool
    let createdByAI: Bool
    let createdAt: Date
    let activeCount: Int
    let completedCount: Int

    init(_ group: TodoGroup) {
        id = group.id
        name = group.name
        isGeneral = group.isGeneral
        createdByAI = group.createdByAI
        createdAt = group.createdAt
        activeCount = group.todos.count { $0.status == .active }
        completedCount = group.todos.count { $0.status == .completed }
    }
}

private struct ClarificationOutput: Encodable {
    let id: UUID
    let todoID: UUID
    let todoTitle: String
    let optionGroupNames: [String]
    let createdAt: Date
    let wasPresented: Bool

    init(_ question: ClarificationQuestion) {
        id = question.id
        todoID = question.todoID
        todoTitle = question.todoTitle
        optionGroupNames = question.optionGroupNames
        createdAt = question.createdAt
        wasPresented = question.wasPresented
    }
}

private struct SnapshotOutput: Encodable {
    let todos: [TodoOutput]
    let groups: [GroupOutput]
    let clarifications: [ClarificationOutput]

    init(context: ModelContext) throws {
        todos = try context.fetch(FetchDescriptor<Todo>())
            .sorted { $0.createdAt > $1.createdAt }
            .map(TodoOutput.init)
        groups = try context.fetch(FetchDescriptor<TodoGroup>())
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(GroupOutput.init)
        clarifications = try context.fetch(FetchDescriptor<ClarificationQuestion>())
            .sorted { $0.createdAt < $1.createdAt }
            .map(ClarificationOutput.init)
    }
}

private struct ConfigOutput: Encodable {
    let baseURL: String
    let chatModel: String
    let embeddingModel: String
    let reasoningBaseURL: String
    let reasoningChatModel: String
    let reasoningAPIKeyConfigured: Bool
    let retentionDays: Int

    init(_ settings: SettingsStore) throws {
        baseURL = settings.baseURL
        chatModel = settings.chatModel
        embeddingModel = settings.embeddingModel
        reasoningBaseURL = settings.reasoningBaseURL
        reasoningChatModel = settings.reasoningChatModel
        reasoningAPIKeyConfigured = try settings.hasReasoningAPIKey()
        retentionDays = settings.retentionDays
    }
}

private enum CLIError: LocalizedError {
    case coded(String, String)

    static func invalid(_ message: String) -> CLIError { .coded("invalid_request", message) }
    static func notFound(_ message: String) -> CLIError { .coded("not_found", message) }
    static func conflict(_ message: String) -> CLIError { .coded("conflict", message) }
    static func busy(_ message: String) -> CLIError { .coded("busy", message) }

    var errorDescription: String? {
        guard case .coded(_, let message) = self else { return nil }
        return message
    }

    var code: String { guard case .coded(let code, _) = self else { return "internal" }; return code }
}

@main
@MainActor
private struct TydoCLI {
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            let mapped = mapError(error)
            try? write(ErrorEnvelope(code: mapped.code, error: mapped.localizedDescription), to: .standardError)
            exit(1)
        }
    }

    private static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first else {
            try printHelp()
            return
        }

        if command == "help" || command == "--help" || command == "-h" {
            try printHelp()
            return
        }
        if command == "version" || command == "--version" {
            guard arguments.count == 1 else { throw CLIError.invalid("Usage: tydo version") }
            try write(Envelope(data: VersionOutput()))
            return
        }

        if command == "config" {
            try await withStoreLock { try configCommand(Array(arguments.dropFirst())) }
            return
        }

        if command == "document" {
            try await documentCommand(Array(arguments.dropFirst()))
            return
        }

        try await withStoreLock {
            let container = try makeTydoModelContainer()
            let context = container.mainContext
            _ = TodoRepository.ensureGeneralGroup(in: context)
            try context.save()
            switch command {
        case "snapshot":
            guard arguments.count == 1 else { throw CLIError.invalid("Usage: tydo snapshot") }
            try write(Envelope(data: try SnapshotOutput(context: context)))
        case "todo":
            try await todoCommand(Array(arguments.dropFirst()), container: container, context: context)
        case "group":
            try groupCommand(Array(arguments.dropFirst()), context: context)
        case "clarification":
            try clarificationCommand(Array(arguments.dropFirst()), context: context)
        case "process":
            guard arguments.count == 1 else { throw CLIError.invalid("Usage: tydo process") }
            try await process(container: container)
            try write(Envelope(data: try SnapshotOutput(context: ModelContext(container))))
        case "mastermind":
            try await mastermindCommand(Array(arguments.dropFirst()), container: container)
        case "maintenance":
            guard arguments.count == 1 else { throw CLIError.invalid("Usage: tydo maintenance") }
            let maintenance = MaintenanceService(modelContainer: container)
            try await withProcessingLock { await maintenance.runCleanup() }
            try write(Envelope(data: try SnapshotOutput(context: ModelContext(container))))
        default:
            throw CLIError.invalid("Unknown command '\(command)'. Run 'tydo help'.")
            }
        }
    }

    private static func todoCommand(
        _ arguments: [String],
        container: ModelContainer,
        context: ModelContext
    ) async throws {
        guard let action = arguments.first else {
            throw CLIError.invalid("Missing todo command. Run 'tydo help'.")
        }
        var values = Array(arguments.dropFirst())

        switch action {
        case "add":
            let shouldProcess = values.contains("--process")
            values.removeAll { $0 == "--process" }
            let text = values.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw CLIError.invalid("Usage: tydo todo add <text> [--process]") }
            let todo = Todo(rawText: text)
            context.insert(todo)
            TodoRepository.logEvent(.created, for: todo, in: context)
            try context.save()
            let id = todo.id
            if shouldProcess { try await process(container: container) }
            try write(Envelope(data: TodoOutput(try fetchTodo(id, in: ModelContext(container)))))

        case "add-many":
            let shouldProcess = values.contains("--process")
            values.removeAll { $0 == "--process" }
            let input = try jsonInput(values)
            let items = try JSONDecoder().decode([String].self, from: Data(input.utf8))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !items.isEmpty else { throw CLIError.invalid("No non-empty todos supplied.") }
            let todos = items.map(Todo.init(rawText:))
            for todo in todos {
                context.insert(todo)
                TodoRepository.logEvent(.created, for: todo, in: context)
            }
            try context.save()
            let ids = todos.map(\.id)
            if shouldProcess { try await process(container: container) }
            let fresh = ModelContext(container)
            try write(Envelope(data: try ids.map { TodoOutput(try fetchTodo($0, in: fresh)) }))

        case "list":
            guard values.count <= 2 else {
                throw CLIError.invalid("Usage: tydo todo list [all|active|completed] [group-id]")
            }
            let status = values.first ?? "all"
            guard ["all", "active", "completed"].contains(status) else {
                throw CLIError.invalid("Status must be all, active, or completed.")
            }
            let groupID = try values.count > 1 ? uuid(values[1], named: "group") : nil
            let todos = try context.fetch(FetchDescriptor<Todo>())
                .filter { status == "all" || $0.status.rawValue == status }
                .filter { groupID == nil || $0.group?.id == groupID }
                .sorted { $0.createdAt > $1.createdAt }
                .map(TodoOutput.init)
            try write(Envelope(data: todos))

        case "show":
            let id = try requiredUUID(values, named: "todo")
            try write(Envelope(data: TodoOutput(try fetchTodo(id, in: context))))

        case "rename":
            guard values.count >= 2 else { throw CLIError.invalid("Usage: tydo todo rename <id> <title>") }
            let id = try uuid(values.removeFirst(), named: "todo")
            let todo = try fetchTodo(id, in: context)
            TodoRepository.rename(todo, to: values.joined(separator: " "), in: context)
            try context.save()
            try write(Envelope(data: TodoOutput(todo)))

        case "complete", "reopen":
            let id = try requiredUUID(values, named: "todo")
            let todo = try fetchTodo(id, in: context)
            if action == "complete" {
                TodoRepository.complete(todo, in: context)
            } else {
                TodoRepository.reopen(todo, in: context)
            }
            try context.save()
            try write(Envelope(data: TodoOutput(todo)))

        case "move":
            guard values.count == 2 else { throw CLIError.invalid("Usage: tydo todo move <todo-id> <group-id>") }
            let todo = try fetchTodo(uuid(values[0], named: "todo"), in: context)
            let group = try fetchGroup(uuid(values[1], named: "group"), in: context)
            TodoRepository.move(todo, to: group, in: context)
            try context.save()
            try write(Envelope(data: TodoOutput(todo)))

        case "unassign":
            let id = try requiredUUID(values, named: "todo")
            let todo = try fetchTodo(id, in: context)
            TodoRepository.unassign(todo, in: context)
            try context.save()
            try write(Envelope(data: TodoOutput(todo)))

        case "delete":
            guard values.count == 2, values[1] == "--yes" else {
                throw CLIError.invalid("Usage: tydo todo delete <id> --yes")
            }
            let id = try uuid(values[0], named: "todo")
            TodoRepository.delete(try fetchTodo(id, in: context), in: context)
            try context.save()
            try write(Envelope(data: MutationOutput(id: id, action: "deleted")))

        default:
            throw CLIError.invalid("Unknown todo command '\(action)'. Run 'tydo help'.")
        }
    }

    private static func groupCommand(_ arguments: [String], context: ModelContext) throws {
        guard let action = arguments.first else { throw CLIError.invalid("Missing group command.") }
        var values = Array(arguments.dropFirst())

        switch action {
        case "list":
            guard values.isEmpty else { throw CLIError.invalid("Usage: tydo group list") }
            let groups = try context.fetch(FetchDescriptor<TodoGroup>())
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map(GroupOutput.init)
            try write(Envelope(data: groups))
        case "create":
            let name = values.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw CLIError.invalid("Usage: tydo group create <name>") }
            try ensureUniqueGroupName(name, excluding: nil, in: context)
            let group = TodoGroup(name: name)
            context.insert(group)
            try context.save()
            try write(Envelope(data: GroupOutput(group)))
        case "rename":
            guard values.count >= 2 else { throw CLIError.invalid("Usage: tydo group rename <id> <name>") }
            let group = try fetchGroup(uuid(values.removeFirst(), named: "group"), in: context)
            guard !group.isGeneral else { throw CLIError.conflict("The General group cannot be renamed.") }
            let name = values.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw CLIError.invalid("Group name cannot be empty.") }
            try ensureUniqueGroupName(name, excluding: group.id, in: context)
            group.name = name
            try context.save()
            try write(Envelope(data: GroupOutput(group)))
        case "delete":
            guard values.count == 2, values[1] == "--yes" else {
                throw CLIError.invalid("Usage: tydo group delete <id> --yes")
            }
            let id = try uuid(values[0], named: "group")
            let group = try fetchGroup(id, in: context)
            guard !group.isGeneral else { throw CLIError.conflict("The General group cannot be deleted.") }
            TodoRepository.deleteGroup(group, in: context)
            try context.save()
            try write(Envelope(data: MutationOutput(id: id, action: "deleted")))
        default:
            throw CLIError.invalid("Unknown group command '\(action)'. Run 'tydo help'.")
        }
    }

    private static func clarificationCommand(_ arguments: [String], context: ModelContext) throws {
        guard let action = arguments.first else { throw CLIError.invalid("Missing clarification command.") }
        var values = Array(arguments.dropFirst())

        switch action {
        case "list":
            guard values.isEmpty else { throw CLIError.invalid("Usage: tydo clarification list") }
            let questions = try context.fetch(FetchDescriptor<ClarificationQuestion>())
                .sorted { $0.createdAt < $1.createdAt }
                .map(ClarificationOutput.init)
            try write(Envelope(data: questions))
        case "mark-presented":
            let id = try requiredUUID(values, named: "clarification")
            let question = try fetchQuestion(id, in: context)
            question.wasPresented = true
            try context.save()
            try write(Envelope(data: ClarificationOutput(question)))
        case "resolve":
            guard values.count >= 2 else {
                throw CLIError.invalid("Usage: tydo clarification resolve <id> <group-name>")
            }
            let id = try uuid(values.removeFirst(), named: "clarification")
            let question = try fetchQuestion(id, in: context)
            try TodoRepository.resolveClarification(
                question,
                choosing: values.joined(separator: " "),
                in: context
            )
            try context.save()
            try write(Envelope(data: MutationOutput(id: id, action: "resolved")))
        default:
            throw CLIError.invalid("Unknown clarification command '\(action)'. Run 'tydo help'.")
        }
    }

    private static func documentCommand(_ arguments: [String]) async throws {
        guard arguments.first == "extract", arguments.count >= 2 else {
            throw CLIError.invalid("Usage: tydo document extract <path>")
        }
        guard arguments.count == 2 else { throw CLIError.invalid("Usage: tydo document extract <path>") }
        let path = arguments.dropFirst().joined(separator: " ")
        let service = DocumentImportService(llm: LLMService(config: SettingsStore.shared.providerConfig))
        try write(Envelope(data: try await service.extractItems(from: URL(fileURLWithPath: path))))
    }

    private static func mastermindCommand(_ arguments: [String], container: ModelContainer) async throws {
        guard let action = arguments.first else { throw CLIError.invalid("Missing mastermind command.") }
        let values = Array(arguments.dropFirst())
        let settings = SettingsStore.shared
        let embeddingLLM = LLMService(config: settings.providerConfig)
        let service = MastermindService(
            modelContainer: container,
            reasoningLLM: LLMService(config: try settings.reasoningProviderConfig()),
            embeddingLLM: embeddingLLM
        )

        switch action {
        case "analyze":
            guard values.count <= 1 else { throw CLIError.invalid("Usage: tydo mastermind analyze [group-id]") }
            let groupID = try values.first.map { try uuid($0, named: "group") }
            if let groupID { _ = try fetchGroup(groupID, in: ModelContext(container)) }
            try write(Envelope(data: try await service.analyze(groupID: groupID)))
        case "accept":
            let input = try jsonInput(values)
            let proposal = try decoder().decode(MastermindProposal.self, from: Data(input.utf8))
            let id = try await service.accept(proposal)
            try write(Envelope(data: TodoOutput(try fetchTodo(id, in: ModelContext(container)))))
        default:
            throw CLIError.invalid("Unknown mastermind command '\(action)'. Run 'tydo help'.")
        }
    }

    private static func configCommand(_ arguments: [String]) throws {
        let settings = SettingsStore.shared
        guard let action = arguments.first else { throw CLIError.invalid("Missing config command.") }

        switch action {
        case "get":
            guard arguments.count == 1 else { throw CLIError.invalid("Usage: tydo config get") }
            try write(Envelope(data: try ConfigOutput(settings)))
        case "update":
            guard arguments.count == 1 else { throw CLIError.invalid("Usage: tydo config update (JSON on stdin)") }
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard !data.isEmpty,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw CLIError.invalid("Expected one JSON object on stdin.")
            }
            let allowed = Set(["version", "baseURL", "chatModel", "embeddingModel", "reasoningBaseURL", "reasoningChatModel", "reasoningAPIKey", "retentionDays"])
            guard Set(object.keys).isSubset(of: allowed) else { throw CLIError.invalid("Config update contains an unknown field.") }
            if let version = object["version"] {
                guard (version as? NSNumber)?.intValue == cliProtocolVersion else {
                    throw CLIError.invalid("Unsupported protocol version.")
                }
            }
            func string(_ key: String, url: Bool = false) throws -> String? {
                guard let value = object[key] else { return nil }
                guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIError.invalid("\(key) must be a non-empty string.")
                }
                if url {
                    guard let parsed = URL(string: value), let scheme = parsed.scheme?.lowercased(),
                          ["http", "https"].contains(scheme), parsed.host != nil else {
                        throw CLIError.invalid("\(key) must be an absolute HTTP(S) URL.")
                    }
                }
                return value
            }
            let baseURL = try string("baseURL", url: true)
            let chatModel = try string("chatModel")
            let embeddingModel = try string("embeddingModel")
            let reasoningBaseURL = try string("reasoningBaseURL", url: true)
            let reasoningChatModel = try string("reasoningChatModel")
            var keyUpdate: String??
            if let value = object["reasoningAPIKey"] {
                if value is NSNull { keyUpdate = .some(nil) }
                else if let value = value as? String, !value.isEmpty { keyUpdate = .some(value) }
                else { throw CLIError.invalid("reasoningAPIKey must be non-empty or null.") }
            }
            var retentionDays: Int?
            if let value = object["retentionDays"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue == Double(number.intValue), (1...365).contains(number.intValue) else {
                    throw CLIError.invalid("retentionDays must be an integer from 1 through 365.")
                }
                retentionDays = number.intValue
            }

            // Keychain is the only throwing write; perform it before infallible defaults updates.
            if let keyUpdate { try settings.setReasoningAPIKey(keyUpdate) }
            if let baseURL { settings.baseURL = baseURL }
            if let chatModel { settings.chatModel = chatModel }
            if let embeddingModel { settings.embeddingModel = embeddingModel }
            if let reasoningBaseURL { settings.reasoningBaseURL = reasoningBaseURL }
            if let reasoningChatModel { settings.reasoningChatModel = reasoningChatModel }
            if let retentionDays { settings.retentionDays = retentionDays }
            try write(Envelope(data: try ConfigOutput(settings)))
        case "set":
            guard arguments.count >= 3 else { throw CLIError.invalid("Usage: tydo config set <key> <value>") }
            let key = arguments[1]
            let value = arguments.dropFirst(2).joined(separator: " ")
            switch key {
            case "base-url": settings.baseURL = value
            case "chat-model": settings.chatModel = value
            case "embedding-model": settings.embeddingModel = value
            case "reasoning-base-url": settings.reasoningBaseURL = value
            case "reasoning-chat-model": settings.reasoningChatModel = value
            case "reasoning-api-key":
                guard !value.isEmpty else { throw CLIError.invalid("reasoning-api-key cannot be empty.") }
                try settings.setReasoningAPIKey(value)
            case "retention-days":
                guard let days = Int(value), (1...365).contains(days) else {
                    throw CLIError.invalid("retention-days must be from 1 through 365.")
                }
                settings.retentionDays = days
            default:
                throw CLIError.invalid("Unknown config key '\(key)'. Run 'tydo help'.")
            }
            try write(Envelope(data: try ConfigOutput(settings)))
        default:
            throw CLIError.invalid("Unknown config command '\(action)'. Run 'tydo help'.")
        }
    }

    private static func process(container: ModelContainer) async throws {
        try await withProcessingLock {
            let settings = SettingsStore.shared
            let llm = LLMService(config: settings.providerConfig)
            let coordinator = ProcessingCoordinator(
                pipeline: PipelineService(modelContainer: container, llm: llm),
                organizer: OrganizerService(modelContainer: container, llm: llm)
            )
            let failures = await coordinator.runPending()
            if !failures.isEmpty {
                let details = failures.map { "\($0.todoID): \($0.message)" }.joined(separator: "; ")
                let code = failures.contains(where: \.timedOut) ? "timeout" : "internal"
                throw CLIError.coded(code, "Processing partially completed: \(details)")
            }
        }
    }

    private static func withProcessingLock(_ operation: () async throws -> Void) async throws {
        let descriptor = try lock(named: "tydo-process.lock")
        defer { close(descriptor) }
        // ponytail: one global worker lock; split it only if independent pipelines appear.
        guard flock(descriptor, LOCK_EX) == 0 else { throw CLIError.busy("Could not acquire the processing lock.") }
        defer { flock(descriptor, LOCK_UN) }
        try await operation()
    }

    private static func withStoreLock(_ operation: () async throws -> Void) async throws {
        let descriptor = try lock(named: "tydo-store.lock")
        defer { close(descriptor) }
        let deadline = Date().addingTimeInterval(2)
        // ponytail: one exclusive store lock; add shared reads only if contention is measured.
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                throw CLIError.coded("internal", "Could not acquire the Tydo store lock.")
            }
            guard Date() < deadline else { throw CLIError.busy("The Tydo store is busy; retry later.") }
            try await Task.sleep(for: .milliseconds(50))
        }
        defer { flock(descriptor, LOCK_UN) }
        try await operation()
    }

    private static func lock(named name: String) throws -> Int32 {
        let directory = tydoDataDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent(name).path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CLIError.coded("internal", "Could not open the Tydo lock.") }
        return descriptor
    }

    private static func fetchTodo(_ id: UUID, in context: ModelContext) throws -> Todo {
        var descriptor = FetchDescriptor<Todo>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let todo = try context.fetch(descriptor).first else {
            throw CLIError.notFound("Todo \(id) was not found.")
        }
        return todo
    }

    private static func fetchGroup(_ id: UUID, in context: ModelContext) throws -> TodoGroup {
        var descriptor = FetchDescriptor<TodoGroup>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let group = try context.fetch(descriptor).first else {
            throw CLIError.notFound("Group \(id) was not found.")
        }
        return group
    }

    private static func fetchQuestion(_ id: UUID, in context: ModelContext) throws -> ClarificationQuestion {
        var descriptor = FetchDescriptor<ClarificationQuestion>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let question = try context.fetch(descriptor).first else {
            throw CLIError.notFound("Clarification \(id) was not found.")
        }
        return question
    }

    private static func ensureUniqueGroupName(_ name: String, excluding id: UUID?, in context: ModelContext) throws {
        let groups = try context.fetch(FetchDescriptor<TodoGroup>())
        guard !groups.contains(where: {
            $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else { throw CLIError.conflict("A group named '\(name)' already exists.") }
    }

    private static func requiredUUID(_ values: [String], named name: String) throws -> UUID {
        guard values.count == 1 else { throw CLIError.invalid("Expected one \(name) ID.") }
        return try uuid(values[0], named: name)
    }

    private static func uuid(_ value: String, named name: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else { throw CLIError.invalid("Invalid \(name) ID '\(value)'.") }
        return id
    }

    private static func jsonInput(_ arguments: [String]) throws -> String {
        if !arguments.isEmpty { return arguments.joined(separator: " ") }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let input = String(data: data, encoding: .utf8), !input.isEmpty else {
            throw CLIError.invalid("Expected JSON as an argument or on stdin.")
        }
        if let object = try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any],
           let version = object["version"], (version as? NSNumber)?.intValue != cliProtocolVersion {
            throw CLIError.invalid("Unsupported protocol version.")
        }
        return input
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func write<Value: Encodable>(_ value: Value, to handle: FileHandle = .standardOutput) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value) + Data("\n".utf8)
        try handle.write(contentsOf: data)
    }

    private static func mapError(_ error: Error) -> CLIError {
        if let error = error as? CLIError { return error }
        if let error = error as? TodoRepository.RepositoryError {
            switch error {
            case .conflict(let message): return .conflict(message)
            case .notFound(let message): return .notFound(message)
            }
        }
        if error is DecodingError || error is DocumentImportService.ImportError {
            return .invalid(error.localizedDescription)
        }
        if let error = error as? CocoaError, error.code == .fileNoSuchFile {
            return .notFound(error.localizedDescription)
        }
        if let error = error as? URLError, error.code == .timedOut {
            return .coded("timeout", error.localizedDescription)
        }
        return .coded("internal", error.localizedDescription)
    }

    private static func printHelp() throws {
        // ponytail: JSON-only output avoids maintaining separate human and machine renderers.
        let help = """
        tydo 1.1.0 - local todo CLI (command results are JSON)

        tydo snapshot
        tydo todo add <text> [--process]
        tydo todo add-many '<json-array>' [--process]
        tydo todo list [all|active|completed] [group-id]
        tydo todo show <id>
        tydo todo rename <id> <title>
        tydo todo complete|reopen <id>
        tydo todo move <todo-id> <group-id>
        tydo todo unassign <todo-id>
        tydo todo delete <id> --yes
        tydo group list
        tydo group create|rename <name-or-id> [name]
        tydo group delete <id> --yes
        tydo clarification list
        tydo clarification mark-presented <id>
        tydo clarification resolve <id> <group-name>
        tydo document extract <path>
        tydo process
        tydo mastermind analyze [group-id]
        tydo mastermind accept '<proposal-json>'
        tydo config get
        tydo config update                 # JSON object on stdin; secrets must use this
        tydo config set <base-url|chat-model|embedding-model|reasoning-base-url|reasoning-chat-model|reasoning-api-key|retention-days> <value>
        tydo maintenance
        tydo version

        Store: ~/Library/Application Support/Tydo/default.store
        Set TYDO_DATA_DIR to override the store/config directory for tests and development.
        Store commands hold one exclusive lock for up to 2 seconds. Provider requests time out
        after 30 seconds (120 seconds total). Document extraction supports pdf, txt, md,
        markdown, doc, docx, rtf, rtfd, html, and htm up to 5 MiB and 64 chunks.
        Commands produce one result only when the whole command succeeds. `process` persists
        each successful stage, so a failure can mean partial progress; refresh before retrying.
        """
        try FileHandle.standardOutput.write(contentsOf: Data((help + "\n").utf8))
    }
}
