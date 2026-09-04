import Foundation
import SwiftData

/// Periodic housekeeping: deletes todos past the retention window and prunes
/// groups that emptied out as a result. Runs once on launch, then on a
/// repeating 6-hour timer, on its own background context.
actor MaintenanceService: ModelActor {
    nonisolated let modelContainer: ModelContainer
    nonisolated let modelExecutor: any ModelExecutor

    private var timerTask: Task<Void, Never>?

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        let context = ModelContext(modelContainer)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
    }

    /// Runs cleanup now, then keeps rerunning every 6 hours until cancelled.
    func start() {
        runCleanup()
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
                guard !Task.isCancelled else { return }
                await self?.runCleanup()
            }
        }
    }

    func runCleanup() {
        let days = SettingsStore.shared.retentionDays
        TodoRepository.deleteExpired(retentionDays: days, in: modelContext)
        TodoRepository.pruneEmptyGroups(in: modelContext)
    }
}
