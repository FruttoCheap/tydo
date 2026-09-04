import SwiftUI
import UniformTypeIdentifiers

/// The contents of the capture panel: a single auto-focused field, plus a
/// "+" button to import todos from a whole document instead of typing them.
/// Enter saves, Shift+Enter inserts a newline, Escape dismisses.
struct CaptureView: View {
    @State private var text = ""
    @FocusState private var focused: Bool
    let initialDocuments: [URL]
    let client: TydoCLIClient
    let onSaved: () -> Void
    let onClose: () -> Void

    private static let placeholders = [
        "Save the world before lunch?",
        "Feed the dragon before it feeds you?",
        "Alphabetize the sock drawer?",
        "Teach the cat to file taxes?",
        "Invent a new color?",
        "Negotiate world peace by Friday?",
        "Find where socks actually go?",
        "Become fluent in penguin?",
    ]
    @State private var placeholder = CaptureView.placeholders.randomElement()!

    private static let importableExtensions =
        ["pdf", "txt", "md", "markdown", "doc", "docx", "rtf", "rtfd", "html", "htm"]
    private static let importableContentTypes = importableExtensions.compactMap { UTType(filenameExtension: $0) }

    @State private var isImportPickerShown = false
    @State private var isImporting = false
    @State private var isSaving = false
    @State private var reviewItems: [String]?
    @State private var importError: String?
    @State private var didHandleInitialDocuments = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { isImportPickerShown = true }) {
                if isImporting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus.circle").font(.title2)
                }
            }
            .buttonStyle(.plain)
            .disabled(isImporting || isSaving)
            .help("Import todos from a document")

            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title)
                .lineLimit(1)
                .focused($focused)
                .onKeyPress { press in
                    switch press.key {
                    case .return:
                        if press.modifiers.contains(.shift) { return .ignored } // newline
                        save()
                        return .handled
                    case .escape:
                        onClose()
                        return .handled
                    default:
                        return .ignored
                    }
                }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: .infinity))
        .overlay(RoundedRectangle(cornerRadius: .infinity).strokeBorder(.separator))
        .padding(10)
        .frame(width: 580)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
            guard !didHandleInitialDocuments else { return }
            didHandleInitialDocuments = true
            importDocuments(initialDocuments)
        }
        .fileImporter(
            isPresented: $isImportPickerShown,
            allowedContentTypes: Self.importableContentTypes,
            allowsMultipleSelection: true,
            onCompletion: handlePickedDocuments
        )
        .sheet(isPresented: Binding(
            get: { reviewItems != nil },
            set: { if !$0 { reviewItems = nil } }
        )) {
            DocumentReviewView(
                items: reviewItems ?? [],
                onConfirm: confirmImport,
                onCancel: { reviewItems = nil }
            )
        }
        .alert("Tydo Error", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { onClose(); return }
        guard !isSaving, !isImporting else { return }
        if trimmed.contains(where: \Character.isNewline) {
            importText(trimmed)
            return
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await client.add(trimmed)
                onSaved()
                onClose()
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    // MARK: - Document import

    private func handlePickedDocuments(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            importDocuments(urls)
        }
    }

    private func importDocuments(_ urls: [URL]) {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                var items: [String] = []
                for url in urls {
                    let extracted: [String]
                    do {
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                        extracted = try await client.extractDocument(at: url)
                    }
                    items.append(contentsOf: extracted)
                }
                showReview(items)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func importText(_ text: String) {
        isImporting = true
        Task {
            defer { isImporting = false }
            do { showReview(try await client.extractText(text)) }
            catch { importError = error.localizedDescription }
        }
    }

    private func showReview(_ items: [String]) {
        if items.isEmpty {
            importError = "No actionable items found."
        } else {
            reviewItems = items
        }
    }

    private func confirmImport(_ items: [String]) {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await client.addMany(items)
                reviewItems = nil
                onSaved()
                onClose()
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}
