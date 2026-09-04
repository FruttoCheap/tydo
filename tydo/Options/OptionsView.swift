import KeyboardShortcuts
import SwiftUI

struct OptionsView: View {
    let client: TydoCLIClient

    var body: some View {
        TabView {
            TodosTab(client: client).tabItem { Label("Todos", systemImage: "list.bullet") }
            GroupsTab(client: client).tabItem { Label("Groups", systemImage: "folder") }
            SettingsTab(client: client).tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .frame(minWidth: 680, minHeight: 460)
        .padding()
        .task { try? await client.refresh() }
    }
}

private struct TodosTab: View {
    let client: TydoCLIClient
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all, active, completed
        var id: String { rawValue }
    }

    private var shown: [TydoTodo] {
        client.snapshot.todos.filter { filter == .all || $0.status == filter.rawValue }
    }

    var body: some View {
        VStack(spacing: 10) {
            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            List {
                ForEach(shown) { todo in
                    TodoRow(client: client, todo: todo, groups: client.snapshot.groups)
                }
            }
        }
    }
}

private struct TodoRow: View {
    let client: TydoCLIClient
    let todo: TydoTodo
    let groups: [TydoGroup]
    @State private var draft = ""
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggleStatus) {
                Image(systemName: todo.status == "completed" ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                TextField("Title", text: $draft, onCommit: commitEdit)
                    .textFieldStyle(.plain)
                    .strikethrough(todo.status == "completed")
                if todo.title != todo.rawText {
                    Text(todo.rawText).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            groupPicker
            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("Delete todo permanently")
        }
        .padding(.vertical, 2)
        .onAppear { draft = todo.title }
        .onChange(of: todo.title) { _, new in draft = new }
        .alert("Tydo Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func toggleStatus() {
        Task {
            do {
                if todo.status == "completed" {
                    try await client.reopen(todo: todo.id)
                } else {
                    try await client.complete(todo: todo.id)
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func commitEdit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != todo.title else { draft = todo.title; return }
        Task {
            do { try await client.rename(todo: todo.id, to: trimmed) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func delete() {
        Task {
            do { try await client.delete(todo: todo.id) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private var groupPicker: some View {
        Picker("", selection: Binding<UUID?>(
            get: { todo.groupID },
            set: { id in
                Task {
                    do {
                        if let id { try await client.move(todo: todo.id, to: id) }
                        else { try await client.unassign(todo: todo.id) }
                    }
                    catch { errorMessage = error.localizedDescription }
                }
            }
        )) {
            Text("Unassigned").tag(UUID?.none)
            ForEach(groups) { group in
                Text(group.name).tag(Optional(group.id))
            }
        }
        .labelsHidden()
        .frame(width: 160)
    }
}

private struct GroupsTab: View {
    let client: TydoCLIClient
    @State private var newName = ""
    @State private var planTarget: PlanTarget?
    @State private var errorMessage: String?

    private enum PlanTarget: Identifiable {
        case group(TydoGroup)
        case everything

        var id: String {
            switch self {
            case .group(let group): group.id.uuidString
            case .everything: "everything"
            }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("New group name", text: $newName).onSubmit(add)
                Button("Add", action: add)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button { planTarget = .everything } label: {
                    Label("Plan everything", systemImage: "wand.and.stars")
                }
            }

            List {
                ForEach(client.snapshot.groups) { group in
                    GroupRow(
                        client: client,
                        group: group,
                        onPlan: { planTarget = .group(group) },
                        onError: { errorMessage = $0 }
                    )
                }
            }
        }
        .sheet(item: $planTarget) { target in
            switch target {
            case .group(let group): MastermindView(client: client, group: group)
            case .everything: MastermindView(client: client, group: nil)
            }
        }
        .alert("Tydo Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func add() {
        let name = newName
        newName = ""
        Task {
            do { try await client.createGroup(named: name) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct GroupRow: View {
    let client: TydoCLIClient
    let group: TydoGroup
    let onPlan: () -> Void
    let onError: (String) -> Void
    @State private var draft = ""

    var body: some View {
        HStack {
            TextField("Name", text: $draft)
                .disabled(group.isGeneral)
                .onSubmit(rename)
            if group.isGeneral {
                Text("default").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(group.activeCount + group.completedCount)").foregroundStyle(.secondary)
            Button(action: onPlan) { Image(systemName: "wand.and.stars") }
                .buttonStyle(.plain)
                .help("Plan this group")
            Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .disabled(group.isGeneral)
        }
        .padding(.vertical, 2)
        .onAppear { draft = group.name }
        .onChange(of: group.name) { _, name in draft = name }
    }

    private func rename() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !group.isGeneral, !name.isEmpty, name != group.name else { draft = group.name; return }
        Task {
            do { try await client.rename(group: group.id, to: name) }
            catch { onError(error.localizedDescription) }
        }
    }

    private func delete() {
        Task {
            do { try await client.delete(group: group.id) }
            catch { onError(error.localizedDescription) }
        }
    }
}

private struct SettingsTab: View {
    let client: TydoCLIClient
    @State private var baseURL = ""
    @State private var chatModel = ""
    @State private var embeddingModel = ""
    @State private var embeddingBaseURL = ""
    @State private var chatAPIKey = ""
    @State private var reasoningBaseURL = ""
    @State private var reasoningChatModel = ""
    @State private var reasoningAPIKey = ""
    @State private var retentionDays = 30
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var commandLinkNotice: String?

    var body: some View {
        Form {
            if !client.snapshot.clarifications.isEmpty {
                Section("Grouping questions") {
                    ForEach(client.snapshot.clarifications) { question in
                        ClarificationCard(question: question) { name in
                            Task {
                                do { try await client.resolve(question.id, choosing: name) }
                                catch { errorMessage = error.localizedDescription }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Section("Hotkeys") {
                KeyboardShortcuts.Recorder("Capture todo:", name: .captureTodo)
                KeyboardShortcuts.Recorder("Show list:", name: .showList)
                KeyboardShortcuts.Recorder("Show options:", name: .showOptions)
            }
            Section("Chat provider") {
                TextField("Base URL", text: $baseURL)
                TextField("Chat model", text: $chatModel)
                SecureField("New API key", text: $chatAPIKey)
            }
            Section("Embedding provider") {
                TextField("Embedding model", text: $embeddingModel)
                TextField("Base URL", text: $embeddingBaseURL, prompt: Text("Same as chat"))
                Text("Leave empty to embed on the chat server. OpenRouter and Groq have no "
                     + "embeddings endpoint, so with those point this at Ollama or LM Studio. "
                     + "Changing the model changes the vector width and stops existing todos "
                     + "from matching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Mastermind reasoning model") {
                TextField("Base URL", text: $reasoningBaseURL)
                TextField("Chat model", text: $reasoningChatModel)
                SecureField("New API key", text: $reasoningAPIKey)
            }
            Section("Maintenance") {
                Stepper(
                    "Keep todos for \(retentionDays) day\(retentionDays == 1 ? "" : "s")",
                    value: $retentionDays,
                    in: 1...365
                )
            }
            Section("Command line") {
                Button("Install \'tydo\' command line tool", action: installCommandLineTool)
                if let commandLinkNotice {
                    Text(commandLinkNotice).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(isSaving ? "Saving..." : "Save Settings", action: save)
                .disabled(isSaving)
        }
        .formStyle(.grouped)
        .task { await load() }
        .alert("Tydo Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func load() async {
        do {
            try await client.loadConfig()
            guard let config = client.config else { return }
            baseURL = config.baseURL
            chatModel = config.chatModel
            embeddingModel = config.embeddingModel
            embeddingBaseURL = config.embeddingBaseURL
            reasoningBaseURL = config.reasoningBaseURL
            reasoningChatModel = config.reasoningChatModel
            retentionDays = config.retentionDays
        } catch { errorMessage = error.localizedDescription }
    }

    private func installCommandLineTool() {
        // Two CLIs of different versions against one store is the likeliest way
        // to corrupt it, so never overwrite an existing install silently.
        if let existing = TydoCLIClient.conflictingInstallation {
            commandLinkNotice = "\(existing.path) already exists. Remove it first "
                + "(or keep using it) — two versions sharing one store is not supported."
            return
        }
        do {
            try client.installCommandLineTool()
            commandLinkNotice = "Linked into \(TydoCLIClient.commandLinkURL.path)."
        } catch { commandLinkNotice = error.localizedDescription }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await client.updateConfig(
                    baseURL: baseURL,
                    chatModel: chatModel,
                    embeddingModel: embeddingModel,
                    embeddingBaseURL: embeddingBaseURL,
                    reasoningBaseURL: reasoningBaseURL,
                    reasoningChatModel: reasoningChatModel,
                    chatAPIKey: chatAPIKey.isEmpty ? nil : chatAPIKey,
                    reasoningAPIKey: reasoningAPIKey.isEmpty ? nil : reasoningAPIKey,
                    retentionDays: retentionDays
                )
                chatAPIKey = ""
                reasoningAPIKey = ""
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

struct ClarificationCard: View {
    let question: TydoClarification
    let onChoose: (String) -> Void
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Which group does this belong to?").font(.headline)
                    Text("\"\(question.todoTitle)\"")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Decide later - keep this in Settings")
                }
            }

            ClarificationFlowRow(spacing: 8) {
                ForEach(question.optionGroupNames, id: \.self) { name in
                    Button(name) { onChoose(name) }.buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

private struct ClarificationFlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct ClarificationPopup: View {
    let client: TydoCLIClient
    let question: TydoClarification
    let onClose: () -> Void
    @State private var errorMessage: String?

    var body: some View {
        ClarificationCard(
            question: question,
            onChoose: { name in
                Task {
                    do {
                        try await client.resolve(question.id, choosing: name)
                        onClose()
                    } catch { errorMessage = error.localizedDescription }
                }
            },
            onDismiss: onClose
        )
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(width: 460)
        .alert("Tydo Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }
}
