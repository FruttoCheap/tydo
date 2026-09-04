import Foundation
import SwiftData

/// Advances captured todos through the AI pipeline: raw → grammar → enriched
/// (with embedding). Stops at `.enriched`; assigning a group is Layer 2.
///
/// Runs as a SwiftData `ModelActor` so it owns a background `ModelContext` and
/// serializes its work — kind to a single local Ollama instance, and safe off
/// the main thread.
///
/// NOTE: verify the ModelActor boilerplate below against your installed SDK —
/// the manual conformance (modelExecutor / DefaultSerialModelExecutor) is the
/// expansion of the @ModelActor macro, written by hand here so we can inject
/// the LLMService.
actor PipelineService: ModelActor {
    nonisolated let modelContainer: ModelContainer
    nonisolated let modelExecutor: any ModelExecutor

    private let llm: LLMService
    private var isRunning = false
    private var rerunRequested = false

    init(modelContainer: ModelContainer, llm: LLMService) {
        self.modelContainer = modelContainer
        let context = ModelContext(modelContainer)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.llm = llm
    }

    /// Process every todo that still needs work, oldest first.
    /// Safe to call after each capture and on launch. Coalesces overlapping
    /// calls: a call that arrives mid-sweep doesn't skip its work, it just
    /// asks the in-flight sweep to loop once more after it finishes — so a
    /// todo captured mid-sweep is never left stranded until the next trigger.
    func processPending() async -> [ProcessingFailure] {
        if isRunning { rerunRequested = true; return [] }
        isRunning = true
        defer { isRunning = false }

        var failures: [ProcessingFailure] = []
        repeat {
            rerunRequested = false
            for todo in pendingTodos() {
                do {
                    try await advance(todo)
                } catch {
                    // Leave the todo at its last good stage; it retries next sweep.
                    // Worst case it stays usable, showing its raw/last-good text.
                    failures.append(ProcessingFailure(todoID: todo.id, error: error))
                }
            }
        } while rerunRequested
        return failures
    }

    // MARK: - Selection

    private func pendingTodos() -> [Todo] {
        // Small N in the prototype: fetch all and filter in memory to sidestep
        // SwiftData enum-predicate sharp edges. Switch to a #Predicate at scale.
        let all = (try? modelContext.fetch(FetchDescriptor<Todo>())) ?? []
        return all
            .filter { $0.status == .active }
            .filter { $0.stage < .enriched || ($0.stage == .enriched && $0.embedding == nil) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Pipeline

    private func advance(_ todo: Todo) async throws {
        // Each substep persists immediately so a crash resumes cleanly.

        if todo.stage == .raw {
            todo.title = try await grammarFix(todo.rawText)
            todo.stage = .grammar
            try modelContext.save()
        }

        if todo.stage == .grammar {
            let result = try await enrich(todo)
            todo.title = result.title
            todo.body = result.body
            todo.stage = .enriched
            TodoRepository.logEvent(.enriched, for: todo, in: modelContext)
            try modelContext.save()
        }

        // Embedding can lag behind .enriched; backfill it without re-enriching,
        // preserving the invariant that .enriched eventually has an embedding.
        if todo.stage == .enriched, todo.embedding == nil {
            var text = todo.title
            if let body = todo.body, !body.isEmpty { text += "\n" + body }
            todo.embedding = try await llm.embed(text)
            if todo.group != nil { todo.stage = .grouped }
            try modelContext.save()
        }
    }

    // MARK: - Steps

    private func grammarFix(_ raw: String) async throws -> String {
        let out = try await llm.chat(
            [ ChatMessage(.system, PipelinePrompts.grammarSystem),
              ChatMessage(.user, raw) ],
            temperature: 0.0
        )
        let cleaned = stripWrapping(out)
        // If the model returned nothing or rambled, keep the user's original.
        guard !cleaned.isEmpty, cleaned.count <= max(40, raw.count * 4) else { return raw }
        return cleaned
    }

    private func enrich(_ todo: Todo) async throws -> (title: String, body: String?) {
        let message = PipelinePrompts.enrichUserMessage(
            todoText: todo.title,
            context: contextBlock(excluding: todo)
        )
        let out = try await llm.chat(
            [ ChatMessage(.system, PipelinePrompts.enrichSystem),
              ChatMessage(.user, message) ],
            temperature: 0.2
        )
        guard let parsed = parseEnrichment(out) else {
            // Graceful degradation: keep the grammar-fixed title, drop the body.
            return (todo.title, nil)
        }
        let title = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = parsed.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? todo.title : title,
                (body?.isEmpty ?? true) ? nil : body)
    }

    // MARK: - Context

    /// Compact, group-labelled list of other active todos for enrichment context.
    private func contextBlock(excluding todo: Todo, limit: Int = 40) -> String {
        let all = (try? modelContext.fetch(FetchDescriptor<Todo>())) ?? []
        let others = all
            .filter { $0.id != todo.id && $0.status == .active }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
        guard !others.isEmpty else { return "(none yet)" }
        // Plain list, no "[Group]" prefix — the model used to copy that bracket
        // format straight into the refined title. Grouping is Layer 2 anyway.
        return others.map { "- \($0.title)" }
            .joined(separator: "\n")
    }

    // MARK: - Parsing helpers

    private func stripWrapping(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") {
            t = String(t.dropFirst().dropLast())
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Enrichment: Decodable { let title: String; let body: String? }

    /// Extract the outermost JSON object even if the model wrapped it in prose
    /// or ```json fences.
    private func parseEnrichment(_ raw: String) -> Enrichment? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end else { return nil }
        let json = String(raw[start...end])
        return try? JSONDecoder().decode(Enrichment.self, from: Data(json.utf8))
    }
}
