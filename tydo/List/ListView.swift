import SwiftUI

/// The floating list modal. Two interchangeable views — Tab flips between
/// them, and the last-used one is persisted so reopening the panel restores it:
///  - carousel: card per group, center card is the ACTIVE group
///  - classic: searchable sectioned list of all active todos
struct ListView: View {
    // ponytail: view choice in UserDefaults, same pattern as activeGroupID.
    @AppStorage("listViewStyle") private var showCarousel = true
    let client: TydoCLIClient
    let onClose: () -> Void

    var body: some View {
        if showCarousel {
            CarouselListView(client: client, onClose: onClose, onSwitch: { showCarousel = false })
        } else {
            ClassicListView(client: client, onClose: onClose, onSwitch: { showCarousel = true })
        }
    }
}

// MARK: - Carousel view

/// Card carousel of groups. The center card is the ACTIVE group — ←/→ (or the
/// chevrons, or clicking a side card) rotate the carousel, and whichever group
/// ends up in the middle is persisted as active. ↑/↓ move the todo selection
/// inside the center card, Enter completes, Tab switches view, Escape closes.
private struct CarouselListView: View {
    let client: TydoCLIClient
    // ponytail: active group lives in UserDefaults as a UUID string — no model
    // migration. Move it into CLI-managed data if it ever needs syncing.
    @AppStorage("activeGroupID") private var activeGroupID = ""
    @State private var centerIndex = 0
    @State private var selectedID: UUID?
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var errorMessage: String?
    @FocusState private var focused: Bool
    @FocusState private var renameFocused: Bool
    let onClose: () -> Void
    let onSwitch: () -> Void

    /// One card per group (empty groups included — they can still be made
    /// active), plus a trailing "Processing…" card for not-yet-grouped todos.
    private var allTodos: [TydoTodo] { client.snapshot.todos }
    private var groups: [TydoGroup] { client.snapshot.groups }

    private var cards: [(group: TydoGroup?, todos: [TydoTodo])] {
        let active = allTodos.filter { $0.status == "active" }
        var result: [(group: TydoGroup?, todos: [TydoTodo])] = groups.map { group in
            (group, active.filter { $0.groupID == group.id })
        }
        let ungrouped = active.filter { $0.groupID == nil }
        if !ungrouped.isEmpty { result.append((nil, ungrouped)) }
        return result
    }

    private var centerCard: (group: TydoGroup?, todos: [TydoTodo])? {
        cards.indices.contains(centerIndex) ? cards[centerIndex] : nil
    }
    // With 2 cards prev == next, so only show the right-hand neighbour.
    private var prevIndex: Int? { cards.count >= 3 ? (centerIndex + cards.count - 1) % cards.count : nil }
    private var nextIndex: Int? { cards.count >= 2 ? (centerIndex + 1) % cards.count : nil }

    private var centerTodos: [TydoTodo] { centerCard?.todos ?? [] }
    private var selectedIndex: Int? { centerTodos.firstIndex { $0.id == selectedID } }

    var body: some View {
        Group {
            if cards.isEmpty {
                ContentUnavailableView("No groups yet", systemImage: "checkmark.circle")
            } else {
                carousel
            }
        }
        .frame(width: 720, height: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress { handleKey($0) }
        .onAppear {
            Task {
                do { try await client.refresh() }
                catch { errorMessage = error.localizedDescription }
                if let index = cards.firstIndex(where: { $0.group?.id.uuidString == activeGroupID }) {
                    centerIndex = index
                }
                selectedID = centerTodos.first?.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
            }
        }
        .alert("Tydo Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private var carousel: some View {
        HStack(spacing: 10) {
            arrow("chevron.left", enabled: cards.count > 1) { rotate(-1) }
            if let prevIndex {
                sideCard(cards[prevIndex]).onTapGesture { rotate(-1) }
            }
            centerCardView
            if let nextIndex {
                sideCard(cards[nextIndex]).onTapGesture { rotate(1) }
            }
            arrow("chevron.right", enabled: cards.count > 1) { rotate(1) }
        }
        .padding(.horizontal, 12)
        .animation(.snappy(duration: 0.2), value: centerIndex)
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.2)
    }

    @ViewBuilder
    private var centerCardView: some View {
        if let card = centerCard {
            VStack(alignment: .leading, spacing: 10) {
                cardTitle(card.group, prominent: true)
                if card.todos.isEmpty {
                    Text("No active todos").foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(card.todos) { todo in
                                    row(todo, selected: todo.id == selectedID)
                                        .id(todo.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture { selectedID = todo.id }
                                }
                            }
                        }
                        .onChange(of: selectedID) { _, id in
                            guard let id else { return }
                            withAnimation { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }
                Text("←→ group · ↑↓ navigate · ⏎ complete · r rename · ⇥ view · esc close")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(width: 260, height: 480)
            .background(RoundedRectangle(cornerRadius: 18).fill(.background.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.separator))
        }
    }

    private func sideCard(_ card: (group: TydoGroup?, todos: [TydoTodo])) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            cardTitle(card.group, prominent: false)
            ForEach(card.todos.prefix(9)) { todo in
                Text(todo.title)
                    .font(.callout).lineLimit(1).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 180, height: 420)
        .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.5)))
    }

    private func cardTitle(_ group: TydoGroup?, prominent: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(group?.color ?? .gray)
                .frame(width: prominent ? 10 : 8, height: prominent ? 10 : 8)
            Text(group?.name ?? "Processing…")
                .font(prominent ? .title2.bold() : .headline)
                .lineLimit(1)
        }
    }

    private func row(_ todo: TydoTodo, selected: Bool) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(group(for: todo)?.color ?? .gray) // .gray = not yet grouped
                .frame(width: 4, height: 22)
            if todo.id == renamingID {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { commitRename(todo) }
            } else {
                Text(todo.title).lineLimit(2)
            }
            Spacer()
            if todo.stage != "grouped" {
                ProgressView()
                    .controlSize(.small)
                    .help("Still processing")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.22) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }

    /// Rotate the carousel; the group now in the middle becomes the active
    /// one. The "Processing…" pseudo-card can be centered but never persists
    /// as active — the last real group keeps that role.
    private func rotate(_ delta: Int) {
        guard cards.count > 1 else { return }
        centerIndex = (centerIndex + delta + cards.count) % cards.count
        if let group = cards[centerIndex].group { activeGroupID = group.id.uuidString }
        selectedID = cards[centerIndex].todos.first?.id
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // While renaming the field owns every key except Escape (cancel);
        // Enter arrives via the field's onSubmit.
        if renamingID != nil {
            if press.key == .escape { cancelRename(); return .handled }
            return .ignored
        }
        switch press.key {
        case .escape:
            onClose(); return .handled
        case .tab:
            onSwitch(); return .handled
        case .leftArrow:
            rotate(-1); return .handled
        case .rightArrow:
            rotate(1); return .handled
        case .downArrow:
            move(by: 1); return .handled
        case .upArrow:
            move(by: -1); return .handled
        case .return:
            completeSelected(); return .handled
        default:
            if press.characters == "r" { startRename(); return .handled }
            return .ignored
        }
    }

    private func startRename() {
        guard let index = selectedIndex else { return }
        let todo = centerTodos[index]
        renameText = todo.title
        renamingID = todo.id
        // The field enters the hierarchy on the next layout pass; focus after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { renameFocused = true }
    }

    private func commitRename(_ todo: TydoTodo) {
        let title = renameText
        cancelRename()
        Task {
            do { try await client.rename(todo: todo.id, to: title) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func cancelRename() {
        renamingID = nil
        focused = true
    }

    private func move(by delta: Int) {
        guard !centerTodos.isEmpty else { return }
        let current = selectedIndex ?? 0
        let next = max(0, min(current + delta, centerTodos.count - 1))
        selectedID = centerTodos[next].id
    }

    private func completeSelected() {
        guard let index = selectedIndex else { return }
        let todo = centerTodos[index]
        let remaining = centerTodos.filter { $0.id != todo.id }
        selectedID = remaining.indices.contains(index) ? remaining[index].id : remaining.last?.id
        Task {
            do {
                try await client.complete(todo: todo.id)
                centerIndex = min(centerIndex, max(0, cards.count - 1))
                if !centerTodos.contains(where: { $0.id == selectedID }) {
                    selectedID = centerTodos.first?.id
                }
            }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func group(for todo: TydoTodo) -> TydoGroup? {
        groups.first { $0.id == todo.groupID }
    }
}

// MARK: - Classic view

/// Keyboard-navigable searchable list of ACTIVE todos, sectioned by group.
/// ↑/↓ move the selection, Enter completes the selected todo, Tab switches
/// back to the carousel, Escape closes.
private struct ClassicListView: View {
    let client: TydoCLIClient
    @State private var selectedID: UUID?
    @State private var query = ""
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var errorMessage: String?
    @FocusState private var searchFocused: Bool
    @FocusState private var renameFocused: Bool
    let onClose: () -> Void
    let onSwitch: () -> Void

    private var allTodos: [TydoTodo] { client.snapshot.todos }
    private var groups: [TydoGroup] { client.snapshot.groups }
    private var active: [TydoTodo] { allTodos.filter { $0.status == "active" } }

    /// Todos grouped by their (possibly nil, i.e. still-processing) group,
    /// filtered by `query` (case- and diacritic-insensitive). A group whose
    /// NAME matches keeps all its todos; otherwise only matching todos survive
    /// and empty groups are dropped entirely.
    private var visibleSections: [(group: TydoGroup?, todos: [TydoTodo])] {
        let byGroup: [UUID?: [TydoTodo]] = Dictionary(grouping: active, by: \TydoTodo.groupID)
        let sections: [(group: TydoGroup?, todos: [TydoTodo])] = byGroup.map { groupID, value in
            let sortedTodos = value.sorted { $0.createdAt > $1.createdAt }
            return (group: groups.first { $0.id == groupID }, todos: sortedTodos)
        }.sorted { ($0.group?.name ?? "") < ($1.group?.name ?? "") }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sections }

        return sections.compactMap { section in
            if let name = section.group?.name, name.localizedStandardContains(trimmed) {
                return section
            }
            let matches = section.todos.filter { $0.title.localizedStandardContains(trimmed) }
            return matches.isEmpty ? nil : (section.group, matches)
        }
    }

    private var visibleTodos: [TydoTodo] { visibleSections.flatMap { $0.todos } }
    private var selectedIndex: Int? { visibleTodos.firstIndex { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBar
            content
        }
        .frame(width: 460, height: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
        .onAppear {
            Task {
                do { try await client.refresh() }
                catch { errorMessage = error.localizedDescription }
                if selectedID == nil { selectedID = visibleTodos.first?.id }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
            }
        }
        .onKeyPress { handleKey($0) }
        .alert("Tydo Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search todos or groups", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onKeyPress { handleKey($0) }
        }
        .padding(.horizontal, 12)
        .padding(.top, 16).padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if visibleTodos.isEmpty {
            ContentUnavailableView(
                query.trimmingCharacters(in: .whitespaces).isEmpty ? "No active todos" : "No matches",
                systemImage: "checkmark.circle"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(visibleSections, id: \.group?.id) { section in
                            sectionHeader(section.group)
                            ForEach(section.todos) { todo in
                                row(todo, selected: todo.id == selectedID)
                                    .id(todo.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { selectedID = todo.id }
                            }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selectedID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func sectionHeader(_ group: TydoGroup?) -> some View {
        HStack(spacing: 6) {
            Text(group?.name ?? "Processing…")
                .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    private func row(_ todo: TydoTodo, selected: Bool) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(groups.first { $0.id == todo.groupID }?.color ?? .gray) // .gray = not yet grouped
                .frame(width: 4, height: 22)
            if todo.id == renamingID {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { commitRename(todo) }
            } else {
                Text(todo.title).lineLimit(2)
            }
            Spacer()
            if todo.stage != "grouped" {
                ProgressView()
                    .controlSize(.small)
                    .help("Still processing")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.22) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // While renaming the field owns every key except Escape (cancel);
        // Enter arrives via the field's onSubmit.
        if renamingID != nil {
            if press.key == .escape { cancelRename(); return .handled }
            return .ignored
        }
        if press.key == .escape { onClose(); return .handled }
        if press.key == .tab { onSwitch(); return .handled }
        if press.characters == "f", press.modifiers.contains(.command) {
            searchFocused = true
            return .handled
        }
        // Plain 'r' belongs to the search box while it's focused, so ⌘R is
        // the always-available rename shortcut here.
        if press.characters == "r",
           press.modifiers.contains(.command) || !searchFocused {
            startRename(); return .handled
        }
        guard !visibleTodos.isEmpty else { return .ignored }
        switch press.key {
        case .downArrow:
            move(by: 1); return .handled
        case .upArrow:
            move(by: -1); return .handled
        case .return:
            completeSelected(); return .handled
        default:
            return .ignored
        }
    }

    private func move(by delta: Int) {
        let current = selectedIndex ?? 0
        let next = max(0, min(current + delta, visibleTodos.count - 1))
        selectedID = visibleTodos[next].id
    }

    private func completeSelected() {
        guard let index = selectedIndex else { return }
        let todo = visibleTodos[index]
        let remaining = visibleTodos.filter { $0.id != todo.id }
        selectedID = remaining.indices.contains(index) ? remaining[index].id : remaining.last?.id
        Task {
            do { try await client.complete(todo: todo.id) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func startRename() {
        guard let index = selectedIndex else { return }
        let todo = visibleTodos[index]
        renameText = todo.title
        renamingID = todo.id
        // The field enters the hierarchy on the next layout pass; focus after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { renameFocused = true }
    }

    private func commitRename(_ todo: TydoTodo) {
        let title = renameText
        cancelRename()
        Task {
            do { try await client.rename(todo: todo.id, to: title) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func cancelRename() {
        renamingID = nil
        searchFocused = true
    }
}

extension TydoGroup {
    /// Stable per-group accent, derived from the group's id so it's fixed the
    /// moment the group is created and never shifts between launches (unlike
    /// Hashable.hashValue, which is per-process randomized). General stays
    /// neutral so themed groups stand out.
    // ponytail: derived from id, not a stored field — no migration. If you need
    // guaranteed-distinct sequential colors or user recoloring, add a stored hex.
    var color: Color {
        if isGeneral { return .gray }
        return Self.palette[Int(id.uuid.0) % Self.palette.count]
    }

    static let palette: [Color] =
        [.blue, .green, .orange, .purple, .pink, .teal, .red, .indigo, .mint, .brown]
}
