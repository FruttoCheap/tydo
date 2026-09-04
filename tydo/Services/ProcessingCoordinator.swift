import Foundation

struct ProcessingFailure: Sendable {
    let todoID: UUID
    let message: String
    let timedOut: Bool

    init(todoID: UUID, error: Error) {
        self.todoID = todoID
        self.message = error.localizedDescription
        self.timedOut = (error as? URLError)?.code == .timedOut
    }
}

/// Single entry point the app calls after each capture and on launch. Wraps
/// the pipeline → organizer chain in the same coalescing pattern each service
/// already uses internally, so a burst of captures during a sweep triggers
/// exactly one more full pass afterward instead of leaving anything stranded
/// below `.grouped`.
actor ProcessingCoordinator {
    private let pipeline: PipelineService
    private let organizer: OrganizerService

    private var isRunning = false
    private var rerunRequested = false

    init(pipeline: PipelineService, organizer: OrganizerService) {
        self.pipeline = pipeline
        self.organizer = organizer
    }

    func runPending() async -> [ProcessingFailure] {
        if isRunning { rerunRequested = true; return [] }
        isRunning = true
        defer { isRunning = false }

        var failures: [ProcessingFailure] = []
        repeat {
            rerunRequested = false
            failures += await pipeline.processPending()
            failures += await organizer.groupPending()
        } while rerunRequested
        return failures
    }
}
