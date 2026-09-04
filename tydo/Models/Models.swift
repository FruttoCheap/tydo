import Foundation
import SwiftData

enum TydoSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static let models: [any PersistentModel.Type] = [
        Todo.self, TodoGroup.self, TodoEvent.self, ClarificationQuestion.self
    ]
}

let tydoSchema = Schema(versionedSchema: TydoSchemaV1.self)

func makeTydoModelContainer() throws -> ModelContainer {
    let directory = tydoDataDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let configuration = ModelConfiguration(
        "Tydo",
        schema: tydoSchema,
        url: directory.appendingPathComponent("default.store")
    )
    return try ModelContainer(for: tydoSchema, configurations: configuration)
}

func tydoDataDirectory() -> URL {
    if let path = ProcessInfo.processInfo.environment["TYDO_DATA_DIR"] {
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
    return URL.applicationSupportDirectory.appendingPathComponent("Tydo", isDirectory: true)
}

// MARK: - Enums

/// Whether a todo is still open or done.
enum TodoStatus: String, Codable {
    case active
    case completed
}

/// How far a todo has progressed through the async AI pipeline.
/// Capture writes `.raw` instantly; the worker advances it stage by stage.
/// Every stage is re-runnable, so re-processing (e.g. after groups change)
/// just means resetting the stage and letting the worker pick it up again.
enum ProcessingStage: String, Codable, Comparable {
    case raw        // just captured, untouched
    case grammar    // grammar-corrected
    case enriched   // title/body refined using context from other todos
    case grouped    // assigned to a group

    private var order: Int {
        switch self {
        case .raw: return 0
        case .grammar: return 1
        case .enriched: return 2
        case .grouped: return 3
        }
    }

    static func < (lhs: ProcessingStage, rhs: ProcessingStage) -> Bool {
        lhs.order < rhs.order
    }
}

// MARK: - Todo

@Model
final class Todo {
    @Attribute(.unique) var id: UUID

    /// The user's original words. NEVER overwritten — `title`/`body` are the
    /// AI-refined view, and the UI should let the user revert to this.
    var rawText: String

    /// Displayed title. Starts equal to `rawText`, refined by the pipeline.
    var title: String

    /// Optional extended content the enrichment step may add.
    var body: String?

    var status: TodoStatus
    var stage: ProcessingStage

    var createdAt: Date
    var completedAt: Date?

    /// Semantic embedding of the *enriched* text, used by the organizer for
    /// nearest-neighbour grouping. Nil until the enrich stage produces it.
    var embedding: [Double]?

    /// Owning group. Nil means "not yet grouped"; the app assigns unmatched
    /// todos to the General group once grouped.
    var group: TodoGroup?

    /// Persisted idempotency key for accepted Mastermind proposals.
    @Attribute(.unique) var acceptedProposalID: UUID?

    init(rawText: String) {
        self.id = UUID()
        self.rawText = rawText
        self.title = rawText
        self.body = nil
        self.status = .active
        self.stage = .raw
        self.createdAt = .now
        self.completedAt = nil
        self.embedding = nil
        self.group = nil
        self.acceptedProposalID = nil
    }

    func markCompleted() {
        status = .completed
        completedAt = .now
    }

    func reopen() {
        status = .active
        completedAt = nil
    }

    /// Revert AI refinements back to the user's original text.
    func revertToRaw() {
        title = rawText
        body = nil
    }
}

// MARK: - TodoGroup

@Model
final class TodoGroup {
    @Attribute(.unique) var id: UUID
    var name: String

    /// The single catch-all bucket for todos the organizer couldn't place.
    var isGeneral: Bool

    var createdAt: Date

    /// True if the organizer created this group (vs. the user).
    var createdByAI: Bool

    /// Deleting a group nullifies its todos' `group` (does NOT delete them);
    /// the app then reassigns those todos to General.
    @Relationship(deleteRule: .nullify, inverse: \Todo.group)
    var todos: [Todo]

    init(name: String, isGeneral: Bool = false, createdByAI: Bool = false) {
        self.id = UUID()
        self.name = name
        self.isGeneral = isGeneral
        self.createdAt = .now
        self.createdByAI = createdByAI
        self.todos = []
    }
}

// MARK: - ClarificationQuestion

/// A grouping decision the organizer refused to guess at: the new todo matched
/// two or more near-identical groups equally well, so instead of committing a
/// coin-flip it parks the todo (left ungrouped) and records this question.
///
/// The app pops it up top-centre for a minute; unanswered, it stays here and
/// surfaces in Settings until the user picks. Answering assigns the todo and
/// deletes the question. Kept deliberately standalone (id, not a relationship)
/// so the todo stays a plain ungrouped todo the normal sweep already skips.
@Model
final class ClarificationQuestion {
    @Attribute(.unique) var id: UUID
    var todoID: UUID
    var todoTitle: String
    /// Candidate group names the organizer was torn between, best match first.
    var optionGroupNames: [String]
    var createdAt: Date
    /// Set once the popup has shown it, so a later sweep doesn't re-popup the
    /// same question — it lives in Settings from then on.
    var wasPresented: Bool

    init(todoID: UUID, todoTitle: String, optionGroupNames: [String]) {
        self.id = UUID()
        self.todoID = todoID
        self.todoTitle = todoTitle
        self.optionGroupNames = optionGroupNames
        self.createdAt = .now
        self.wasPresented = false
    }
}

// MARK: - TodoEvent

/// What happened to a todo. Persisted as an append-only log — fuel for a
/// future "mastermind" feature; nothing reads this yet.
enum TodoEventType: String, Codable {
    case created, completed, reopened, edited, reverted, deleted, enriched, grouped
}

/// A snapshot of one thing that happened to a todo. Deliberately NOT related
/// to `Todo` (no `@Relationship`, no cascade) — `todoID`/`todoTitle` are
/// denormalized copies so the log survives the todo's deletion.
@Model
final class TodoEvent {
    @Attribute(.unique) var id: UUID
    var todoID: UUID
    var todoTitle: String
    var groupName: String?
    var type: TodoEventType
    var timestamp: Date
    var detail: String?

    init(todoID: UUID, todoTitle: String, groupName: String? = nil,
         type: TodoEventType, detail: String? = nil) {
        self.id = UUID()
        self.todoID = todoID
        self.todoTitle = todoTitle
        self.groupName = groupName
        self.type = type
        self.timestamp = .now
        self.detail = detail
    }
}
