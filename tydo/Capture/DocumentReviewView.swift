import SwiftUI

/// Checklist shown after a document import extracts candidate todos. Nothing
/// is written until "Add" — read-then-commit, same shape as MastermindView's
/// analyze/accept split.
struct DocumentReviewView: View {
    let items: [String]
    let onConfirm: ([String]) -> Void
    let onCancel: () -> Void

    @State private var selected: Set<Int>

    init(items: [String], onConfirm: @escaping ([String]) -> Void, onCancel: @escaping () -> Void) {
        self.items = items
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _selected = State(initialValue: Set(items.indices))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Found \(items.count) item\(items.count == 1 ? "" : "s")")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items.indices, id: \.self) { index in
                        Toggle(items[index], isOn: Binding(
                            get: { selected.contains(index) },
                            set: { isOn in
                                if isOn { selected.insert(index) } else { selected.remove(index) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Add \(selected.count)") {
                    onConfirm(items.indices.filter(selected.contains).map { items[$0] })
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 320)
    }
}
