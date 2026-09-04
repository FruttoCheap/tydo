import Foundation
import SwiftData

/// Assigns enriched todos to groups. For each ungrouped `.enriched` todo it
/// retrieves the nearest existing groups (by centroid) and nearest loose todos
/// in General (by vector), hands that short, ranked candidate set to the LLM,
/// and applies one of three decisions: assign / new group / General.
///
/// Runs as a SwiftData `ModelActor` (background context, serialized work). The
/// manual ModelActor conformance mirrors PipelineService — verify it against
/// your installed SDK, or collapse to @ModelActor and inject `llm` via a setter.
actor OrganizerService: ModelActor {
    nonisolated let modelContainer: ModelContainer
    nonisolated let modelExecutor: any ModelExecutor

    private let llm: LLMService
    private var isRunning = false
    private var rerunRequested = false

    // Tuning knobs.
    private let maxGroupCandidates = 3
    private let maxLooseCandidates = 5
    // Ambiguity guard: if the top themed groups are BOTH strong matches and
    // near-tied, the LLM's pick is a coin-flip between look-alike groups — so
    // ask the user instead of guessing. Tune to taste for your embedding model.
    private let clarifyMinScore = 0.80   // both candidates must be real matches
    private let clarifyMaxDelta = 0.05   // ...and this close in score to count as tied

    init(modelContainer: ModelContainer, llm: LLMService) {
        self.modelContainer = modelContainer
        let context = ModelContext(modelContainer)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.llm = llm
    }

    /// Group every enriched, embedded, ungrouped todo (oldest first) so each new
    /// todo sees the groups its predecessors formed. Coalesces overlapping
    /// calls the same way `PipelineService.processPending()` does.
    func groupPending() async -> [ProcessingFailure] {
        if isRunning { rerunRequested = true; return [] }
        isRunning = true
        defer { isRunning = false }

        var failures: [ProcessingFailure] = []
        repeat {
            rerunRequested = false
            for todo in pendingTodos() {
                do { try await group(todo) }
                catch {
                    failures.append(ProcessingFailure(todoID: todo.id, error: error))
                }
            }
        } while rerunRequested
        return failures
    }

    // MARK: - Selection

    private func pendingTodos() -> [Todo] {
        let all = (try? modelContext.fetch(FetchDescriptor<Todo>())) ?? []
        // Todos already awaiting a user clarification are parked, not pending —
        // otherwise the sweep would re-ask the same question every run.
        let awaiting = Set(
            ((try? modelContext.fetch(FetchDescriptor<ClarificationQuestion>())) ?? [])
                .map { $0.todoID }
        )
        return all
            .filter { $0.status == .active && $0.stage == .enriched && $0.group == nil && $0.embedding != nil }
            .filter { !awaiting.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Grouping a single todo

    private func group(_ todo: Todo) async throws {
        guard let vector = todo.embedding else { return }

        let groups = activeGroups()
        let general = ensureGeneralGroup(in: groups)

        // Nearest existing themed groups, by centroid similarity.
        let groupCandidates = groups
            .filter { !$0.isGeneral }
            .compactMap { g -> (group: TodoGroup, score: Double)? in
                guard let c = centroid(of: g) else { return nil }
                return (g, cosineSimilarity(vector, c))
            }
            .sorted { $0.score > $1.score }
            .prefix(maxGroupCandidates)
            .map { $0 }

        // Nearest loose todos in General — candidates to co-found a new group.
        let looseCandidates = general.todos
            .filter { $0.id != todo.id && $0.status == .active && $0.embedding != nil }
            .map { (todo: $0, score: cosineSimilarity(vector, $0.embedding!)) }
            .sorted { $0.score > $1.score }
            .prefix(maxLooseCandidates)
            .map { $0 }

        let decision = try await decide(
            todo: todo,
            groupCandidates: groupCandidates,
            looseCandidates: looseCandidates
        )

        // Guard: the LLM wants to assign, but two+ look-alike groups matched
        // near-equally well and its pick is among them → don't guess, ask.
        // Park the todo (leave it ungrouped) with a pending question.
        if case .assign(let name) = decision {
            let tied = ambiguousTie(among: groupCandidates)
            if tied.count >= 2, tied.contains(where: { $0.name == name }) {
                enqueueClarification(for: todo, options: tied)
                return
            }
        }

        apply(decision, to: todo, general: general, looseCandidates: looseCandidates)
        todo.stage = .grouped
        TodoRepository.logEvent(.grouped, for: todo, in: modelContext)
        try modelContext.save()
    }

    // MARK: - Decision

    private enum Decision {
        case assign(groupName: String)
        case newGroup(name: String, includeNumbers: [Int])
        case general
    }

    private func decide(
        todo: Todo,
        groupCandidates: [(group: TodoGroup, score: Double)],
        looseCandidates: [(todo: Todo, score: Double)]
    ) async throws -> Decision {

        let groupsBlock = groupCandidates.isEmpty
            ? "(none yet besides General)"
            : groupCandidates.map { c in
                let examples = c.group.todos
                    .filter { $0.id != todo.id }
                    .prefix(3)
                    .map { "\"\($0.title)\"" }
                    .joined(separator: ", ")
                let base = "- \"\(c.group.name)\" (similarity \(fmt(c.score)))"
                return examples.isEmpty ? base : base + " — e.g. \(examples)"
            }.joined(separator: "\n")

        let looseBlock = looseCandidates.isEmpty
            ? "(none)"
            : looseCandidates.enumerated().map { i, c in
                "\(i + 1). \"\(c.todo.title)\" (similarity \(fmt(c.score)))"
            }.joined(separator: "\n")

        let message = OrganizerPrompts.userMessage(
            todoTitle: todo.title,
            todoBody: todo.body,
            groupsBlock: groupsBlock,
            looseBlock: looseBlock
        )

        let out = try await llm.chat(
            [ ChatMessage(.system, OrganizerPrompts.system),
              ChatMessage(.user, message) ],
            temperature: 0.1
        )

        guard let raw = parseDecision(out) else { return .general }
        switch raw.action.lowercased() {
        case "assign":
            if let g = raw.group, !g.isEmpty { return .assign(groupName: g) }
            return .general
        case "new_group":
            if let n = raw.name, !n.isEmpty {
                return .newGroup(name: n, includeNumbers: raw.include ?? [])
            }
            return .general
        default:
            return .general
        }
    }

    // MARK: - Applying the decision (with guardrails)

    private func apply(
        _ decision: Decision,
        to todo: Todo,
        general: TodoGroup,
        looseCandidates: [(todo: Todo, score: Double)]
    ) {
        switch decision {
        case .assign(let name):
            // Only honor names that map to a real, non-General group.
            if let g = activeGroups().first(where: { !$0.isGeneral && $0.name == name }) {
                todo.group = g
            } else {
                todo.group = general
            }

        case .newGroup(let name, let numbers):
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { todo.group = general; return }
            let newGroup: TodoGroup
            if let existing = activeGroups().first(where: {
                $0.name.caseInsensitiveCompare(clean) == .orderedSame
            }) {
                newGroup = existing
            } else {
                newGroup = TodoGroup(name: clean, createdByAI: true)
                modelContext.insert(newGroup)
            }
            todo.group = newGroup
            // Pull in only listed candidates that are still loose in General.
            for n in numbers {
                let idx = n - 1
                guard looseCandidates.indices.contains(idx) else { continue }
                let loose = looseCandidates[idx].todo
                if loose.group?.isGeneral ?? true { loose.group = newGroup }
            }

        case .general:
            todo.group = general
        }
    }

    // MARK: - Ambiguity

    /// The set of near-tied, strong-match themed groups the LLM can't reliably
    /// tell apart: the top candidate must clear `clarifyMinScore`, and every
    /// returned group sits within `clarifyMaxDelta` of it. Fewer than 2 ⇒ no
    /// ambiguity (returns them anyway; the caller checks `count >= 2`).
    private func ambiguousTie(
        among candidates: [(group: TodoGroup, score: Double)]
    ) -> [TodoGroup] {
        guard let top = candidates.first, top.score >= clarifyMinScore else { return [] }
        return candidates
            .filter { top.score - $0.score <= clarifyMaxDelta }
            .map { $0.group }
    }

    /// Records a pending question for a todo, unless one already exists for it.
    /// The todo is left ungrouped/enriched — `pendingTodos()` skips it until the
    /// user answers (which assigns it) or the question is otherwise resolved.
    private func enqueueClarification(for todo: Todo, options: [TodoGroup]) {
        let existing = (try? modelContext.fetch(FetchDescriptor<ClarificationQuestion>())) ?? []
        guard !existing.contains(where: { $0.todoID == todo.id }) else { return }
        let q = ClarificationQuestion(
            todoID: todo.id,
            todoTitle: todo.title,
            optionGroupNames: options.map { $0.name }
        )
        modelContext.insert(q)
        try? modelContext.save()
    }

    // MARK: - Helpers

    private func activeGroups() -> [TodoGroup] {
        (try? modelContext.fetch(FetchDescriptor<TodoGroup>())) ?? []
    }

    private func ensureGeneralGroup(in groups: [TodoGroup]) -> TodoGroup {
        if let g = groups.first(where: { $0.isGeneral }) { return g }
        let g = TodoGroup(name: "General", isGeneral: true)
        modelContext.insert(g)
        return g
    }

    /// Elementwise mean of a group's member embeddings; nil if none are embedded.
    private func centroid(of group: TodoGroup) -> [Double]? {
        let vectors = group.todos.compactMap { $0.embedding }.filter { !$0.isEmpty }
        guard let dim = vectors.first?.count, dim > 0 else { return nil }
        var sum = [Double](repeating: 0, count: dim)
        for v in vectors where v.count == dim {
            for i in 0..<dim { sum[i] += v[i] }
        }
        let n = Double(vectors.count)
        return sum.map { $0 / n }
    }

    private func fmt(_ d: Double) -> String { String(format: "%.2f", d) }

    private struct RawDecision: Decodable {
        let action: String
        let group: String?
        let name: String?
        let include: [Int]?
    }

    private func parseDecision(_ raw: String) -> RawDecision? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end else { return nil }
        let json = String(raw[start...end])
        return try? JSONDecoder().decode(RawDecision.self, from: Data(json.utf8))
    }
}
