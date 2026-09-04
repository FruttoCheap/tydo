import Foundation
import SwiftData

/// One proposed next-action todo. Sendable so it can cross from the actor to
/// the UI; nothing is written to the store until the user accepts it.
struct MastermindProposal: Codable, Sendable, Identifiable {
    let id: UUID
    let title: String
    let body: String?
    let rationale: String
    let group: String

    init(id: UUID = UUID(), title: String, body: String?, rationale: String, group: String) {
        self.id = id
        self.title = title
        self.body = body
        self.rationale = rationale
        self.group = group
    }
}

/// Result of one `analyze(groupID:)` call. Read-only — inserting anything
/// happens only in `accept(_:)`.
struct MastermindResult: Codable, Sendable {
    let summary: String
    let proposals: [MastermindProposal]
}

/// The manual, on-demand planner — Layer 4. For one user-selected group it
/// reads that group's todos and event history, asks the (separately
/// configured) reasoning model to assess momentum and propose next actions,
/// and lets the user accept or dismiss each proposal.
///
/// Runs as a SwiftData `ModelActor` (background context), matching the
/// pattern of `PipelineService`/`OrganizerService`. `analyze` never writes;
/// `accept` is the only mutating path.
actor MastermindService: ModelActor {
    nonisolated let modelContainer: ModelContainer
    nonisolated let modelExecutor: any ModelExecutor

    /// Swappable planning model — separate from the app's main chat config.
    private let reasoningLLM: LLMService
    /// The app's SHARED embedding service. Accepted todos must be embedded
    /// with this, not the reasoning provider, or their vectors won't compare
    /// against the rest of the app's todos.
    private let embeddingLLM: LLMService

    private let maxCompletedTodos = 20
    private let maxEvents = 100

    init(modelContainer: ModelContainer, reasoningLLM: LLMService, embeddingLLM: LLMService) {
        self.modelContainer = modelContainer
        let context = ModelContext(modelContainer)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.reasoningLLM = reasoningLLM
        self.embeddingLLM = embeddingLLM
    }

    // MARK: - analyze (read-only)

    /// `groupID` nil means "the whole list" — every group, all at once —
    /// instead of one user-selected group.
    func analyze(groupID: UUID?) async throws -> MastermindResult {
        let message: String
        if let groupID {
            guard let group = fetchGroup(groupID) else {
                return MastermindResult(summary: "That group no longer exists.", proposals: [])
            }
            message = groupMessage(for: group)
        } else {
            message = wholeListMessage()
        }

        let out = try await reasoningLLM.chat(
            [ ChatMessage(.system, MastermindPrompts.system),
              ChatMessage(.user, message) ],
            temperature: 0.7
        )

        return parseResult(out) ?? MastermindResult(
            summary: "The planner's response couldn't be read, so no proposals were generated.",
            proposals: []
        )
    }

    private func groupMessage(for group: TodoGroup) -> String {
        let active = group.todos
            .filter { $0.status == .active }
            .sorted { $0.createdAt < $1.createdAt }
        let completed = group.todos
            .filter { $0.status == .completed }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .prefix(maxCompletedTodos)

        let todoIDs = Set(group.todos.map(\.id))
        let events = allEvents()
            .filter { $0.groupName == group.name || todoIDs.contains($0.todoID) }
            .sorted { $0.timestamp < $1.timestamp }
            .suffix(maxEvents)

        return MastermindPrompts.userMessage(
            scopeName: group.name,
            activeBlock: activeBlock(active),
            completedBlock: completedBlock(Array(completed)),
            eventsBlock: eventsBlock(Array(events)),
            groupsBlock: groupsOverview(excluding: group)
        )
    }

    private func wholeListMessage() -> String {
        let allTodos = (try? modelContext.fetch(FetchDescriptor<Todo>())) ?? []

        let active = allTodos
            .filter { $0.status == .active }
            .sorted { $0.createdAt < $1.createdAt }
        let completed = allTodos
            .filter { $0.status == .completed }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .prefix(maxCompletedTodos)
        let events = allEvents()
            .sorted { $0.timestamp < $1.timestamp }
            .suffix(maxEvents)

        return MastermindPrompts.userMessage(
            scopeName: "the entire list (all groups)",
            activeBlock: activeBlock(active, labelGroup: true),
            completedBlock: completedBlock(Array(completed), labelGroup: true),
            eventsBlock: eventsBlock(Array(events), labelGroup: true),
            groupsBlock: groupsOverview(excluding: nil)
        )
    }

    // MARK: - accept (the ONLY mutating path)

    @discardableResult
    func accept(_ proposal: MastermindProposal) async throws -> UUID {
        let proposalID: UUID? = proposal.id
        var accepted = FetchDescriptor<Todo>(predicate: #Predicate { $0.acceptedProposalID == proposalID })
        accepted.fetchLimit = 1
        if let existing = try modelContext.fetch(accepted).first { return existing.id }
        let group = resolveGroup(named: proposal.group)

        let todo = Todo(rawText: proposal.title)
        todo.body = proposal.body
        todo.group = group
        todo.stage = .grouped
        todo.acceptedProposalID = proposal.id
        modelContext.insert(todo)

        var text = todo.title
        if let body = todo.body, !body.isEmpty { text += "\n" + body }
        do { todo.embedding = try await embeddingLLM.embed(text) }
        catch { todo.stage = .enriched }

        TodoRepository.logEvent(.created, for: todo, detail: "mastermind", in: modelContext)
        try modelContext.save()
        return todo.id
    }

    // MARK: - Group resolution

    private func resolveGroup(named name: String) -> TodoGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return TodoRepository.ensureGeneralGroup(in: modelContext) }
        let groups = (try? modelContext.fetch(FetchDescriptor<TodoGroup>())) ?? []
        if let existing = groups.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        let created = TodoGroup(name: trimmed, createdByAI: true)
        modelContext.insert(created)
        return created
    }

    // MARK: - Context assembly

    private func fetchGroup(_ id: UUID) -> TodoGroup? {
        var descriptor = FetchDescriptor<TodoGroup>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func allEvents() -> [TodoEvent] {
        (try? modelContext.fetch(FetchDescriptor<TodoEvent>())) ?? []
    }

    /// `excluding` nil means "the whole list" — list every group instead of
    /// every OTHER group.
    private func groupsOverview(excluding group: TodoGroup?) -> String {
        let groups = (try? modelContext.fetch(FetchDescriptor<TodoGroup>())) ?? []
        let shown = group.map { g in groups.filter { $0.id != g.id } } ?? groups
        guard !shown.isEmpty else { return group == nil ? "(no groups)" : "(no other groups)" }
        return shown.map { g in
            "- \(g.name) (\(g.todos.filter { $0.status == .active }.count) active)"
        }.joined(separator: "\n")
    }

    private func activeBlock(_ todos: [Todo], labelGroup: Bool = false) -> String {
        guard !todos.isEmpty else { return "(none)" }
        return todos.map { t in
            let label = labelGroup ? " [\(t.group?.name ?? "Unassigned")]" : ""
            return "- \"\(t.title)\"\(label) (active \(daysSince(t.createdAt))d)"
        }.joined(separator: "\n")
    }

    private func completedBlock(_ todos: [Todo], labelGroup: Bool = false) -> String {
        guard !todos.isEmpty else { return "(none)" }
        return todos.map { t in
            let label = labelGroup ? " [\(t.group?.name ?? "Unassigned")]" : ""
            return "- \"\(t.title)\"\(label) (completed \(dateFmt.string(from: t.completedAt ?? t.createdAt)))"
        }.joined(separator: "\n")
    }

    private func eventsBlock(_ events: [TodoEvent], labelGroup: Bool = false) -> String {
        guard !events.isEmpty else { return "(none)" }
        return events.map { e in
            let label = labelGroup ? " [\(e.groupName ?? "Unassigned")]" : ""
            let detail = e.detail.map { " (\($0))" } ?? ""
            return "- \(dateFmt.string(from: e.timestamp)) \(e.type.rawValue) \"\(e.todoTitle)\"\(label)\(detail)"
        }.joined(separator: "\n")
    }

    private func daysSince(_ date: Date) -> Int {
        max(0, Calendar.current.dateComponents([.day], from: date, to: .now).day ?? 0)
    }

    private let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Parsing

    private struct RawProposal: Decodable {
        let title: String
        let body: String?
        let rationale: String
        let group: String
    }

    private struct RawResult: Decodable {
        let summary: String
        let proposals: [RawProposal]
    }

    /// Extract the outermost JSON object even if the model wrapped it in prose
    /// or ```json fences; nil on any parse failure (never crashes).
    private func parseResult(_ raw: String) -> MastermindResult? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end else { return nil }
        let json = String(raw[start...end])
        guard let decoded = try? JSONDecoder().decode(RawResult.self, from: Data(json.utf8)) else { return nil }
        let proposals = decoded.proposals.map {
            MastermindProposal(title: $0.title, body: $0.body, rationale: $0.rationale, group: $0.group)
        }
        return MastermindResult(summary: decoded.summary, proposals: proposals)
    }
}
