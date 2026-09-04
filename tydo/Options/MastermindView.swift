import SwiftUI

/// "Plan this group" / "Plan everything": runs the matching CLI command,
/// then shows the summary and each proposal as an Accept/Dismiss card.
/// Read-only until the user taps Accept — nothing is written by opening or
/// running this view. `group` nil means "the whole list".
struct MastermindView: View {
    let client: TydoCLIClient
    let group: TydoGroup?

    @State private var isRunning = false
    @State private var result: TydoMastermindResult?
    @State private var hiddenIDs: Set<UUID> = []
    @State private var errorMessage: String?

    private var title: String { group.map { "Plan: \($0.name)" } ?? "Plan: everything" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(action: runAnalyze) {
                    if isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(group == nil ? "Plan everything" : "Plan this group")
                    }
                }
                .disabled(isRunning) // the ONLY reentrancy guard; the service has none by design
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let result {
                        Text(result.summary).font(.subheadline)
                        ForEach(result.proposals) { proposal in
                            if !hiddenIDs.contains(proposal.id) {
                                proposalCard(proposal)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 440, minHeight: 340)
    }

    private func proposalCard(_ proposal: TydoMastermindProposal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(proposal.title).fontWeight(.semibold)
            if let body = proposal.body, !body.isEmpty {
                Text(body).font(.caption)
            }
            Text(proposal.rationale).font(.caption).foregroundStyle(.secondary)
            Text("→ \(proposal.group)").font(.caption2).foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Dismiss") { hiddenIDs.insert(proposal.id) }
                Button("Accept") { accept(proposal) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func runAnalyze() {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        Task {
            defer { isRunning = false }
            do {
                result = try await client.analyze(groupID: group?.id)
                hiddenIDs = []
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func accept(_ proposal: TydoMastermindProposal) {
        Task {
            do {
                try await client.accept(proposal)
                hiddenIDs.insert(proposal.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
