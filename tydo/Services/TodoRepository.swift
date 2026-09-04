import Foundation
import SwiftData

/// Deterministic data operations. No AI here — grouping done in this file is
/// the manual user-driven kind; the organizer's auto-grouping comes later.
enum TodoRepository {
    enum RepositoryError: LocalizedError {
        case conflict(String)
        case notFound(String)
        var errorDescription: String? {
            switch self {
            case .conflict(let message), .notFound(let message): return message
            }
        }
    }

    /// Returns the General group, creating it if missing (first-launch seed).
    @discardableResult
    static func ensureGeneralGroup(in context: ModelContext) -> TodoGroup {
        var descriptor = FetchDescriptor<TodoGroup>(predicate: #Predicate { $0.isGeneral })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let general = TodoGroup(name: "General", isGeneral: true)
        context.insert(general)
        try? context.save()
        return general
    }

    static func createGroup(named name: String, in context: ModelContext) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        context.insert(TodoGroup(name: trimmed))
        try? context.save()
    }

    /// Deletes a group, reassigning its todos to General first. Never deletes
    /// todos, and refuses to delete the General group itself.
    static func deleteGroup(_ group: TodoGroup, in context: ModelContext) {
        guard !group.isGeneral else { return }
        let general = ensureGeneralGroup(in: context)
        for todo in group.todos {
            todo.group = general
        }
        context.delete(group)
        try? context.save()
    }

    static func move(_ todo: Todo, to group: TodoGroup, in context: ModelContext) {
        todo.group = group
        todo.stage = .grouped
        logEvent(.grouped, for: todo, in: context)
        try? context.save()
        pruneEmptyGroups(in: context)
    }

    // MARK: - Status changes

    static func complete(_ todo: Todo, in context: ModelContext) {
        todo.markCompleted()
        logEvent(.completed, for: todo, in: context)
        try? context.save()
        pruneEmptyGroups(in: context)
    }

    /// User-driven rename. Final — only touches `title` (never `rawText`) and
    /// does NOT reset the pipeline stage, so the AI won't overwrite it.
    static func rename(_ todo: Todo, to newTitle: String, in context: ModelContext) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != todo.title else { return }
        todo.title = trimmed
        logEvent(.edited, for: todo, detail: "renamed", in: context)
        try? context.save()
    }

    static func reopen(_ todo: Todo, in context: ModelContext) {
        todo.reopen()
        logEvent(.reopened, for: todo, in: context)
        try? context.save()
    }

    /// Logs a `.deleted` snapshot event, then removes the todo.
    static func delete(_ todo: Todo, in context: ModelContext) {
        logEvent(.deleted, for: todo, in: context)
        let questions = (try? context.fetch(FetchDescriptor<ClarificationQuestion>())) ?? []
        for question in questions where question.todoID == todo.id { context.delete(question) }
        context.delete(todo)
        try? context.save()
    }

    // MARK: - Clarifications

    /// Answer a parked grouping question: assign its todo to the chosen group,
    /// advance it to `.grouped`, log it, and delete the question. Falls back to
    /// General if the chosen group no longer exists. No-op if the todo is gone.
    static func resolveClarification(
        _ question: ClarificationQuestion,
        choosing groupName: String,
        in context: ModelContext
    ) throws {
        let cleanName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard question.optionGroupNames.contains(where: {
            $0.caseInsensitiveCompare(cleanName) == .orderedSame
        }) else { throw RepositoryError.conflict("That clarification choice is stale or invalid.") }
        let todoID = question.todoID
        var descriptor = FetchDescriptor<Todo>(predicate: #Predicate { $0.id == todoID })
        descriptor.fetchLimit = 1
        guard let todo = try context.fetch(descriptor).first else {
            throw RepositoryError.notFound("The todo for this clarification no longer exists.")
        }
        let groups = try context.fetch(FetchDescriptor<TodoGroup>())
        guard let group = groups.first(where: {
            $0.name.caseInsensitiveCompare(cleanName) == .orderedSame
        }) else { throw RepositoryError.conflict("That clarification group no longer exists.") }
        todo.group = group
        todo.stage = .grouped
        logEvent(.grouped, for: todo, in: context)
        context.delete(question)
        try? context.save()
    }

    static func unassign(_ todo: Todo, in context: ModelContext) {
        let wasAssigned = todo.group != nil
        let previousStage = todo.stage
        todo.group = nil
        if todo.embedding != nil || todo.body != nil { todo.stage = .enriched }
        else if todo.title != todo.rawText { todo.stage = .grammar }
        else { todo.stage = .raw }
        let questions = (try? context.fetch(FetchDescriptor<ClarificationQuestion>())) ?? []
        let stale = questions.filter { $0.todoID == todo.id }
        for question in stale { context.delete(question) }
        if wasAssigned || previousStage != todo.stage || !stale.isEmpty {
            logEvent(.edited, for: todo, detail: "unassigned", in: context)
        }
        try? context.save()
    }

    // MARK: - Event log

    /// Appends a `TodoEvent` snapshot. Usable from any `ModelContext` (main
    /// or a service's background context). Does not save — callers already
    /// save after their own mutation, so this piggybacks on that.
    @discardableResult
    static func logEvent(
        _ type: TodoEventType,
        for todo: Todo,
        detail: String? = nil,
        in context: ModelContext
    ) -> TodoEvent {
        let event = TodoEvent(
            todoID: todo.id,
            todoTitle: todo.title,
            groupName: todo.group?.name,
            type: type,
            detail: detail
        )
        context.insert(event)
        return event
    }

    // MARK: - Cleanup

    /// Any non-General group left with no active todos is dead weight: its
    /// remaining (completed) todos move to General and the group is deleted.
    static func pruneEmptyGroups(in context: ModelContext) {
        let groups = (try? context.fetch(FetchDescriptor<TodoGroup>())) ?? []
        guard groups.contains(where: { !$0.isGeneral }) else { return }
        let general = ensureGeneralGroup(in: context)
        for group in groups where !group.isGeneral {
            guard !group.todos.contains(where: { $0.status == .active }) else { continue }
            for todo in group.todos { todo.group = general }
            context.delete(group)
        }
        try? context.save()
    }

    /// Deletes completed todos whose completion is older than `retentionDays`.
    /// Logs a `.deleted` snapshot for each before
    /// removing it, then prunes any group that emptied out as a result.
    static func deleteExpired(retentionDays: Int, in context: ModelContext) {
        let cutoff = Date.now.addingTimeInterval(-Double(retentionDays) * 86_400)
        let all = (try? context.fetch(FetchDescriptor<Todo>())) ?? []
        let expired = all.filter { $0.status == .completed && ($0.completedAt ?? .distantFuture) < cutoff }
        guard !expired.isEmpty else { return }
        for todo in expired {
            logEvent(.deleted, for: todo, in: context)
            context.delete(todo)
        }
        try? context.save()
        pruneEmptyGroups(in: context)
    }
}
