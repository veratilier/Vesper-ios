import SwiftUI

struct ChatPromptEditor: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("vesperPalette") private var palette = "blue"
    let api: APIClient
    let contact: String
    @State private var draft: String
    @State private var original: String
    @State private var saveError: String?
    init(api: APIClient, contact: String) {
        self.api = api; self.contact = contact
        let text = ChatOrganization.load(api).contactInstructions ?? ChatPromptPreferences.load()
        _draft = State(initialValue: text); _original = State(initialValue: text)
    }
    @State private var confirmingDiscard = false
    private var changed: Bool { draft != original }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("写下你希望 \(contact) 如何与你聊天。")
                    .font(.subheadline).foregroundStyle(VesperTheme.muted)
                TextEditor(text: $draft)
                    .font(.body).scrollContentBackground(.hidden)
                    .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .vesperGlass(in: RoundedRectangle(cornerRadius: 22))
                    .accessibilityLabel("Chat prompt text").accessibilityIdentifier("chat-prompt-editor")
                Text("仅用于这个联系人的所有对话，保存在本机。下一条消息生效；项目可以添加自己的要求。清空并保存即可停用。不修改自唤醒。")
                    .font(.caption).foregroundStyle(VesperTheme.muted)
            }.padding(20).background { Background() }
                .navigationTitle("Contact instruction").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { if changed { confirmingDiscard = true } else { dismiss() } }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            do {
                                var organization = ChatOrganization.load(api)
                                organization.contactInstructions = draft
                                try organization.save(api)
                                original = draft; dismiss()
                            } catch { saveError = error.localizedDescription }
                        }.accessibilityIdentifier("chat-prompt-save")
                    }
                }
                .confirmationDialog("放弃未保存的修改？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                    Button("放弃修改", role: .destructive) { dismiss() }
                    Button("继续编辑", role: .cancel) {}
                }
        }.foregroundStyle(VesperTheme.ink).tint(VesperTheme.ink)
            .preferredColorScheme(palette == "black" ? .dark : .light)
            .interactiveDismissDisabled(changed)
            .alert("Could not save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: { Text(saveError ?? "") }
            .presentationDetents([.large]).presentationDragIndicator(.visible)
    }
}

/// Owner-authored jobs run on VPS even when Vesper is closed. Heartbeat has its own page.
struct ScheduledTasksView: View {
    let defaultConversationID: String
    let conversations: [JSONValue]
    let onOpenSidebar: (() -> Void)?
    init(defaultConversationID: String, conversations: [JSONValue], onOpenSidebar: (() -> Void)? = nil) {
        self.defaultConversationID = defaultConversationID
        self.conversations = conversations
        self.onOpenSidebar = onOpenSidebar
    }
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var tasks: [JSONValue] = []
    @State private var runs: [JSONValue] = []
    @State private var editing: JSONValue?
    @State private var showingEditor = false
    @State private var loading = false
    @State private var notice = ""
    private var activeTasks: [JSONValue] { tasks.filter { $0["enabled"].bool } }
    private var completedTasks: [JSONValue] { tasks.filter { isCompleted($0) } }
    private var pausedTasks: [JSONValue] { tasks.filter { !$0["enabled"].bool && !isCompleted($0) } }

    var body: some View {
        Group {
            #if targetEnvironment(macCatalyst)
            VStack(spacing: 0) {
                WallpaperInlineHeader("Scheduled Tasks") {
                    if let onOpenSidebar {
                        Button(action: onOpenSidebar) {
                            Image(systemName: "line.3.horizontal")
                                .frame(width: 44, height: 44)
                                .vesperMaterial(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain).accessibilityLabel("Open chat sidebar")
                    } else {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .frame(width: 44, height: 44)
                                .vesperMaterial(.ultraThinMaterial, in: Circle())
                        }.buttonStyle(.plain).accessibilityLabel("Back")
                    }
                } trailing: {
                    Button { editing = nil; showingEditor = true } label: {
                        Image(systemName: "plus")
                            .frame(width: 44, height: 44)
                            .vesperMaterial(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New scheduled task")
                    .accessibilityIdentifier("scheduled-task-new")
                }
                taskScroll
            }
            .background { Background() }
            .toolbar(.hidden, for: .navigationBar)
            #else
            taskScroll
                .background { Background() }
                .navigationTitle("Scheduled Tasks").navigationBarTitleDisplayMode(.inline).transparentNavigationTop()
                .toolbar { ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = nil; showingEditor = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New scheduled task")
                        .accessibilityIdentifier("scheduled-task-new")
                } }
            #endif
        }
        .sheet(isPresented: $showingEditor) {
            ScheduledTaskEditor(task: editing, defaultConversationID: defaultConversationID,
                                conversations: conversations) {
                showingEditor = false
                Task { await load() }
            }.environmentObject(store)
        }
        .task { if tasks.isEmpty { await load() } }
        .refreshable { await load() }
    }

    private var taskScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !notice.isEmpty {
                    GlassCard { Text(notice).font(.subheadline).textSelection(.enabled) }
                }
                if tasks.isEmpty && !loading {
                    GlassCard {
                        ContentUnavailableView("No scheduled tasks", systemImage: "calendar.badge.clock",
                                               description: Text("Ask Ash in Chat to schedule something, or tap + to create it yourself."))
                            .frame(maxWidth: .infinity)
                    }
                }
                if !activeTasks.isEmpty { taskGlassSection("Active", items: activeTasks) }
                if !pausedTasks.isEmpty { taskGlassSection("Paused", items: pausedTasks) }
                if !completedTasks.isEmpty { taskGlassSection("Completed", items: completedTasks) }
                if !runs.isEmpty { runsGlassSection }
            }
            .padding(20).frame(maxWidth: 780).frame(maxWidth: .infinity)
        }
    }

    private func taskGlassSection(_ title: String, items: [JSONValue]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).padding(.leading, 8)
            VStack(spacing: 0) {
                ForEach(items) { task in
                    Button { editing = task; showingEditor = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: task["enabled"].bool ? "clock.badge.checkmark" :
                                    isCompleted(task) ? "checkmark.circle" : "pause.circle")
                                .font(.system(size: 20)).frame(width: 26)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task["title"].string).font(.body.weight(.medium))
                                Text(summary(task)).font(.caption).foregroundStyle(VesperTheme.muted)
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(VesperTheme.muted)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if task.id != items.last?.id { Divider().padding(.horizontal, 18) }
                }
            }
            .vesperGlass(in: RoundedRectangle(cornerRadius: 25))
        }
    }

    private var runsGlassSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent runs").font(.headline).padding(.leading, 8)
            VStack(spacing: 0) {
                ForEach(Array(runs.prefix(10))) { run in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(run["title"].string).font(.subheadline)
                            Text(Date(timeIntervalSince1970: run["due"].number).formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(VesperTheme.muted)
                        }
                        Spacer()
                        Text(run["status"].string.capitalized).font(.caption)
                            .foregroundStyle(VesperTheme.muted)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    if run.id != runs.prefix(10).last?.id { Divider().padding(.horizontal, 18) }
                }
            }
            .vesperGlass(in: RoundedRectangle(cornerRadius: 25))
        }
    }

    private func isCompleted(_ task: JSONValue) -> Bool {
        !task["enabled"].bool && task["schedule"]["kind"].string == "once" &&
            task["schedule"]["at"].number <= Date().timeIntervalSince1970
    }

    private func summary(_ task: JSONValue) -> String {
        if isCompleted(task) { return "Completed" }
        guard task["enabled"].bool else { return "Paused" }
        let schedule = task["schedule"]
        let cadence: String
        switch schedule["kind"].string {
        case "interval": cadence = "Every \(Int(schedule["everyMinutes"].number)) minutes"
        case "daily": cadence = "Every day"
        case "weekly": cadence = "Every week"
        default: cadence = "Once"
        }
        let next = task["nextAt"].number
        return next > 0 ? cadence + " · " + Date(timeIntervalSince1970: next).formatted(date: .abbreviated, time: .shortened) : cadence
    }

    private func load() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            let response = try await store.api.request("/scheduled-tasks", history: true)
            tasks = response["tasks"].array
            runs = response["recentRuns"].array
            notice = ""
        } catch { notice = error.localizedDescription }
    }
}

private struct ScheduledTaskEditor: View {
    let task: JSONValue?
    let defaultConversationID: String
    let conversations: [JSONValue]
    let saved: () -> Void
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var prompt = ""
    @State private var cadence = "once"
    @State private var once = Date().addingTimeInterval(3600)
    @State private var hour = 9
    @State private var minute = 0
    @State private var everyMinutes = 60
    @State private var weekday = 1
    @State private var timeZone = TimeZone.current.identifier
    @State private var conversationID = ""
    @State private var enabled = true
    @State private var busy = false
    @State private var notice = ""
    @State private var confirmDelete = false
    private let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    private var cannotSave: Bool {
        busy || (cadence == "interval" && !(5...10080).contains(everyMinutes)) ||
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            #if targetEnvironment(macCatalyst)
            VStack(spacing: 0) {
                WallpaperInlineHeader(task == nil ? "New Task" : "Edit Task") {
                    Button("Cancel") { dismiss() }
                        .disabled(busy).buttonStyle(.plain)
                } trailing: {
                    Button(busy ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(cannotSave).buttonStyle(.plain)
                }
                taskEditorScroll
            }
            .background { Background() }
            .toolbar(.hidden, for: .navigationBar)
            #else
            taskEditorScroll
                .background { Background() }
                .navigationTitle(task == nil ? "New Task" : "Edit Task")
                .navigationBarTitleDisplayMode(.inline)
                .transparentNavigationTop()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(busy ? "Saving…" : "Save") { Task { await save() } }
                            .disabled(cannotSave)
                    }
                }
            #endif
        }
        .task { fill() }
    }

    private var taskEditorScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                editorGlassSection("Task") {
                    TextField("Title", text: $title).scheduledEditorRow()
                    Divider().padding(.horizontal, 18)
                    TextEditor(text: $prompt)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 130)
                        .accessibilityLabel("Task instructions")
                        .scheduledEditorRow()
                    Divider().padding(.horizontal, 18)
                    Text("Tell Ash what to do when this task runs. His result will appear in the selected chat.")
                        .font(.caption).foregroundStyle(VesperTheme.muted).scheduledEditorRow()
                }
                editorGlassSection("When") {
                    HStack {
                        Text("Repeat")
                        Spacer()
                        Picker("Repeat", selection: $cadence) {
                            Text("Once").tag("once")
                            Text("Every interval").tag("interval")
                            Text("Every day").tag("daily")
                            Text("Every week").tag("weekly")
                        }.labelsHidden().pickerStyle(.menu)
                    }.scheduledEditorRow()
                    Divider().padding(.horizontal, 18)
                    if cadence == "once" {
                        DatePicker("Run at", selection: $once, displayedComponents: [.date, .hourAndMinute])
                            .scheduledEditorRow()
                        Divider().padding(.horizontal, 18)
                    } else if cadence == "interval" {
                        HStack {
                            Text("Every")
                            Spacer()
                            TextField("Minutes", value: $everyMinutes, format: .number)
                                .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                                .frame(width: 90)
                            Text("minutes")
                        }.scheduledEditorRow()
                        Divider().padding(.horizontal, 18)
                        Text("5 minutes to 7 days. Ash can choose this interval for you when you ask in Chat.")
                            .font(.caption).foregroundStyle(VesperTheme.muted).scheduledEditorRow()
                        Divider().padding(.horizontal, 18)
                    } else {
                        if cadence == "weekly" {
                            Picker("Day", selection: $weekday) {
                                ForEach(1...7, id: \.self) { day in Text(weekdays[day - 1]).tag(day) }
                            }.scheduledEditorRow()
                            Divider().padding(.horizontal, 18)
                        }
                        Picker("Hour", selection: $hour) {
                            ForEach(0..<24, id: \.self) { value in Text(String(format: "%02d", value)).tag(value) }
                        }.scheduledEditorRow()
                        Divider().padding(.horizontal, 18)
                        Picker("Minute", selection: $minute) {
                            ForEach(0..<60, id: \.self) { value in Text(String(format: "%02d", value)).tag(value) }
                        }.scheduledEditorRow()
                        Divider().padding(.horizontal, 18)
                        Text("Time zone: " + timeZone).font(.caption).foregroundStyle(VesperTheme.muted).scheduledEditorRow()
                        Divider().padding(.horizontal, 18)
                    }
                    Toggle("Enabled", isOn: $enabled).scheduledEditorRow()
                }
                editorGlassSection("Send result to") {
                    if conversations.isEmpty {
                        Text("Current chat").foregroundStyle(VesperTheme.muted).scheduledEditorRow()
                    } else {
                        Picker("Chat", selection: $conversationID) {
                            ForEach(conversations) { conversation in
                                Text(conversation["title"].string.isEmpty ? "Chat" : conversation["title"].string)
                                    .tag(conversation.id)
                            }
                        }.scheduledEditorRow()
                    }
                }
                if let task {
                    editorGlassSection("Task actions") {
                        Button("Delete task", role: .destructive) { confirmDelete = true }
                            .disabled(busy).scheduledEditorRow()
                    }
                    .confirmationDialog("Delete \(task["title"].string)?", isPresented: $confirmDelete) {
                        Button("Delete task", role: .destructive) { Task { await delete() } }
                    }
                }
                if !notice.isEmpty {
                    editorGlassSection("Status") { Text(notice).font(.subheadline).textSelection(.enabled).scheduledEditorRow() }
                }
            }
            .padding(20).frame(maxWidth: 780).frame(maxWidth: .infinity)
        }
    }

    private func editorGlassSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).padding(.leading, 8)
            VStack(spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .vesperGlass(in: RoundedRectangle(cornerRadius: 25))
        }
    }

    private func fill() {
        conversationID = task?["conversationId"].string ?? defaultConversationID
        guard let task else { return }
        title = task["title"].string
        prompt = task["prompt"].string
        cadence = task["schedule"]["kind"].string
        enabled = task["enabled"].bool
        if cadence == "once" { once = Date(timeIntervalSince1970: task["schedule"]["at"].number) }
        else if cadence == "interval" { everyMinutes = Int(task["schedule"]["everyMinutes"].number) }
        else {
            hour = Int(task["schedule"]["hour"].number)
            minute = Int(task["schedule"]["minute"].number)
            weekday = max(1, Int(task["schedule"]["weekday"].number))
            timeZone = task["schedule"]["timeZone"].string
        }
    }

    private var schedule: JSONValue {
        if cadence == "once" {
            return .object(["kind": .string("once"), "at": .number(once.timeIntervalSince1970)])
        }
        if cadence == "interval" {
            return .object(["kind": .string("interval"), "everyMinutes": .number(Double(everyMinutes))])
        }
        var value: [String: JSONValue] = ["kind": .string(cadence), "hour": .number(Double(hour)),
            "minute": .number(Double(minute)), "timeZone": .string(timeZone)]
        if cadence == "weekly" { value["weekday"] = .number(Double(weekday)) }
        return .object(value)
    }

    private func save() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        var body: [String: JSONValue] = ["action": .string(task == nil ? "create" : "update"),
            "title": .string(title), "prompt": .string(prompt), "schedule": schedule,
            "conversationId": .string(conversationID), "enabled": .bool(enabled)]
        if let task {
            body["id"] = task["id"]
            body["revision"] = task["revision"]
        }
        do {
            _ = try await store.api.request("/scheduled-tasks", method: "POST", body: .object(body), history: true)
            saved()
        } catch { notice = error.localizedDescription }
    }

    private func delete() async {
        guard let task, !busy else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await store.api.request("/scheduled-tasks", method: "POST", body: .object([
                "action": .string("delete"), "id": task["id"], "revision": task["revision"]]), history: true)
            saved()
        } catch { notice = error.localizedDescription }
    }
}

private extension View {
    func scheduledEditorRow() -> some View {
        padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChatProjectEditor: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("vesperPalette") private var palette = "blue"
    @State private var draft: ChatProject
    @State private var discard = false
    @State private var saveError: String?
    let original: ChatProject
    let isNew: Bool
    let save: (ChatProject) throws -> Void
    init(project: ChatProject, isNew: Bool, save: @escaping (ChatProject) throws -> Void) {
        original = project; self.isNew = isNew; self.save = save
        _draft = State(initialValue: project)
    }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Project name", text: $draft.name)
                    .font(.title2.weight(.semibold)).padding(16)
                    .vesperGlass(in: RoundedRectangle(cornerRadius: 20))
                    .accessibilityIdentifier("chat-project-name")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(ChatProject.icons, id: \.self) { symbol in
                            Button { draft.icon = symbol } label: {
                                Image(systemName: symbol).font(.title3).frame(width: 44, height: 44)
                                    .background(draft.symbol == symbol ? VesperTheme.ink.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain).accessibilityLabel(symbol)
                                .accessibilityAddTraits(draft.symbol == symbol ? .isSelected : [])
                        }
                    }
                }.accessibilityLabel("Project icon")
                Label("Instruction", systemImage: "doc.text").font(.headline)
                TextEditor(text: $draft.instructions).scrollContentBackground(.hidden)
                    .padding(12).vesperGlass(in: RoundedRectangle(cornerRadius: 22))
                    .accessibilityLabel("Project instruction").accessibilityIdentifier("chat-project-instruction")
                Text("只在这个项目的对话中使用，下一条消息生效。各对话仍有独立的聊天上下文。项目分组和 Instruction 保存在本机。")
                    .font(.caption).foregroundStyle(VesperTheme.muted)
            }.padding(20).background { Background() }
                .navigationTitle(isNew ? "New project" : "Project settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { if draft != original { discard = true } else { dismiss() } }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                            do { try save(draft); dismiss() } catch { saveError = error.localizedDescription }
                        }.disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("chat-project-save")
                    }
                }
        }.foregroundStyle(VesperTheme.ink).tint(VesperTheme.ink)
            .preferredColorScheme(palette == "black" ? .dark : .light)
            .presentationDetents([.large]).presentationDragIndicator(.visible)
            .interactiveDismissDisabled(draft != original)
            .confirmationDialog("Discard changes?", isPresented: $discard) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .alert("Could not save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: { Text(saveError ?? "") }
    }
}

struct NativeChatHome: View {
    var sideBySide = VesperLayout.isMac
    var onMenu: (() -> Void)? = nil
    var onOpenMusic: (() -> Void)? = nil
    var onRootVisibilityChange: (Bool) -> Void = { _ in }
    @Environment(\.chatWorkspace) private var workspace
    var body: some View {
        if let workspace {
            ChatWorkspaceHome(workspace: workspace, sideBySide: sideBySide, onMenu: onMenu,
                              onOpenMusic: onOpenMusic, onRootVisibilityChange: onRootVisibilityChange)
        } else {
            NativeChatBackendHome(sideBySide: sideBySide, onMenu: onMenu,
                                  onOpenMusic: onOpenMusic, onRootVisibilityChange: onRootVisibilityChange)
        }
    }
}

private struct ChatWorkspaceHome: View {
    @ObservedObject var workspace: ChatBackendWorkspace
    var sideBySide: Bool
    var onMenu: (() -> Void)?
    var onOpenMusic: (() -> Void)?
    var onRootVisibilityChange: (Bool) -> Void
    var body: some View {
        let runtime = workspace.runtime(workspace.selectedBackend)
        NativeChatBackendHome(sideBySide: sideBySide, onMenu: onMenu,
                              onOpenMusic: onOpenMusic, onRootVisibilityChange: onRootVisibilityChange)
            .environmentObject(runtime.store).environmentObject(runtime.chat).environmentObject(runtime.chat.composer)
            .id(workspace.selectedBackend)
    }
}

// Keep the sliding drawer inside the screen width while letting scroll content
// continue behind the status bar, floating tabs, and music accessory.
private struct ChatPaneClip: Shape {
    var topInset: CGFloat
    var bottomInset: CGFloat
    var cornerRadius: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let bounds = CGRect(x: rect.minX, y: rect.minY - topInset,
                            width: rect.width, height: rect.height + topInset + bottomInset)
        return RoundedRectangle(cornerRadius: cornerRadius).path(in: bounds)
    }
}

private struct NativeChatBackendHome: View {
    var sideBySide = VesperLayout.isMac
    var onMenu: (() -> Void)? = nil
    var onOpenMusic: (() -> Void)? = nil
    var onRootVisibilityChange: (Bool) -> Void = { _ in }
    @EnvironmentObject private var chat: ChatSession
    @EnvironmentObject private var store: AppStore
    @Environment(\.chatWorkspace) private var workspace
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.vesperChatTabSelected) private var chatTabSelected
    private enum Destination: Equatable { case conversation, scheduledTasks, space, projects, project(String), activity }
    @State private var projectTab = "Chats"
    @State private var projectDrafts: [String: String] = [:]
    @State private var startingProjectChat = false
    @State private var destination = Destination.conversation
    @State private var drawerOpen = true
    @State private var welcomeLine = "A place for today, too."
    @State private var contactsVisible = false
    @State private var open = false
    @State private var loadingChat = false
    @State private var openingTask: Task<Void, Never>?
    @State private var searching = false
    @State private var showingFavorites = false
    @State private var showingChatPrompt = false
    @State private var showingAvatarSettings = false
    @State private var organization = ChatOrganization()
    @State private var editingProject: ChatProject?
    @State private var deletingProject: ChatProject?
    @State private var expandedProjects: Set<String> = []
    @State private var showingActivity = false
    @State private var openedOnce = false
    @State private var deletingConversation: JSONValue?
    @State private var deleting = false
    @State private var renamingConversation: JSONValue?
    @State private var conversationTitle = ""
    @State private var renaming = false
    @State private var activityRefreshID = 0
    @AppStorage("chat-contact.vps.window") private var vpsWindowID = ""
    private var selectedBackend: VesperBackend { store.activeBackend }
    @StateObject private var backendContacts = ChatBackendContacts()
    private var selectedContacts: ChatBackendContactSnapshot {
        backendContacts.activeSnapshot(selectedBackend, api: store.api, profile: store.document("profile"),
                                       conversations: chat.conversations(for: store.api))
    }
    private var windowSelection: Binding<String> {
        $vpsWindowID
    }
    private var selectedClient: APIClient {
        backendContacts.client(selectedBackend) ?? APIClient(baseURL: selectedContacts.baseURL, historyURL: BackendConnection.load(selectedBackend).historyURL, token: "")
    }
    private var mainConversationID: String {
        selectedContacts.mainID
    }
    private var rowDisabled: Bool { startingProjectChat || store.loading || loadingChat || chat.busy || chat.openingMainRoom || chat.callActive || deleting || renaming }
    var body: some View {
        Group {
            if sideBySide {
                HStack(spacing: 0) {
                    NavigationStack { contactsWithDialogs }.frame(width: 300)
                        .frame(width: drawerOpen ? 300 : 0, alignment: .leading).clipped()
                        .allowsHitTesting(drawerOpen).accessibilityHidden(!drawerOpen)
                    if drawerOpen { Divider() }
                    conversationPane.frame(maxWidth: .infinity)
                }
            } else {
                GeometryReader { geometry in
                    let width = min(340, geometry.size.width * 0.77)
                    ZStack(alignment: .leading) {
                        Background()
                        NavigationStack { contactsWithDialogs }
                            .frame(width: width)
                            .offset(x: drawerOpen ? 0 : -width)
                            .allowsHitTesting(drawerOpen)
                            .accessibilityHidden(!drawerOpen)
                            .accessibilityIdentifier("chat-sidebar")
                        conversationPane
                            .frame(width: geometry.size.width)
                            .allowsHitTesting(!drawerOpen)
                            .accessibilityHidden(drawerOpen)
                            .overlay {
                                if drawerOpen {
                                    Color.black.opacity(0.08).contentShape(Rectangle())
                                        .onTapGesture { setDrawer(false) }
                                        .accessibilityLabel("Close chat sidebar")
                                        .accessibilityAddTraits(.isButton)
                                }
                            }
                            .clipShape(ChatPaneClip(topInset: geometry.safeAreaInsets.top,
                                                   bottomInset: max(geometry.safeAreaInsets.bottom, 160),
                                                   cornerRadius: drawerOpen ? 28 : 0))
                            .shadow(color: .black.opacity(drawerOpen ? 0.18 : 0), radius: 18, x: -8)
                            .offset(x: drawerOpen ? width : 0)
                        if !drawerOpen {
                            Color.clear.frame(width: 20).contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 20).onEnded { value in
                                    if value.translation.width > 45 && abs(value.translation.height) < abs(value.translation.width) { setDrawer(true) }
                                })
                                .accessibilityHidden(true)
                        }
                    }.clipShape(ChatPaneClip(topInset: geometry.safeAreaInsets.top,
                                             bottomInset: max(geometry.safeAreaInsets.bottom, 160)))
                        .simultaneousGesture(DragGesture(minimumDistance: 25).onEnded { value in
                            if drawerOpen && value.translation.width < -60 && abs(value.translation.height) < abs(value.translation.width) { setDrawer(false) }
                        })
                }
            }
        }
        .onChange(of: drawerOpen) { _, value in
            contactsVisible = value
            onRootVisibilityChange(!value && destination != .conversation)
        }
        .background {
            if drawerOpen { sidebarBackground } else { Background() }
        }
        .toolbar(drawerOpen && !sideBySide ? .hidden : .visible, for: .tabBar)
        .transparentChatBottom()
    }

    private func setDrawer(_ visible: Bool, animated: Bool = true) {
        if visible { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        withAnimation(reduceMotion || !animated ? nil : .spring(response: 0.32, dampingFraction: 0.88)) { drawerOpen = visible }
    }
    private var conversationPane: some View {
        NavigationStack {
            ZStack {
                Background()
                if destination != .conversation {
                    destinationPage
                } else if loadingChat && !chat.showingCachedHistory {
                    VStack(spacing: 20) {
                        ProgressView("Opening chat…")
                        Button("Show chats") { setDrawer(true) }
                    }
                } else if open {
                    ChatView(onMenu: { setDrawer(!drawerOpen) },
                             restoreLatest: false, inbox: workspace?.runtime(store.activeBackend).inbox)
                        .environment(\.vesperChatTabSelected, chatTabSelected && !drawerOpen && destination == .conversation)
                        .frame(maxWidth: 920).toolbar(.hidden, for: .navigationBar)
                } else {
                    VStack(spacing: 20) {
                        ContentUnavailableView("Your conversations", systemImage: "bubble.left.and.bubble.right",
                                               description: Text(chat.error ?? "Choose a conversation, or start a new one."))
                        Button { setDrawer(true) } label: {
                            Label("Show chats", systemImage: "sidebar.left")
                                .padding(16).vesperGlass(in: Capsule(), interactive: true)
                        }.buttonStyle(.plain).padding(.bottom, 32)
                    }
                }
            }
        }
    }

    private func navigate(_ target: Destination) {
        if destination != target { projectTab = "Chats" }
        destination = target; setDrawer(false)
    }
    @ViewBuilder private var destinationPage: some View {
        Group {
            switch destination {
            case .scheduledTasks:
                ScheduledTasksView(defaultConversationID: workspace?.vps.chat.conversationID ?? chat.conversationID,
                                   conversations: workspace?.vps.chat.conversations ?? chat.conversations,
                                   onOpenSidebar: { setDrawer(true) })
                    .environmentObject(workspace?.vps.store ?? store)
            case .space:
                ChatSpaceView(api: store.api) { item in
                    Task {
                        if await chat.openSearchResult(.object(["id": .string(item.messageID), "conversationId": .string(item.conversationID)])) {
                            destination = .conversation; open = true; setDrawer(false)
                        }
                    }
                }
            case .projects:
                projectDirectory
            case .project(let id):
                if let project = organization.projects.first(where: { $0.id == id }) { projectPage(project) }
                else { projectDirectory }
            case .activity:
                ScrollView { ChatActivityHeatmap(refreshID: activityRefreshID, client: selectedClient).padding(20) }
                    .navigationTitle("Our days")
            case .conversation: EmptyView()
            }
        }.toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { setDrawer(true) } label: { Image(systemName: "line.3.horizontal") }
                    .accessibilityLabel("Open chat sidebar")
            }
        }
    }
    private var sidebarBackground: some View {
        (VesperTheme.palette == .black ? Color(white: 0.07) : Color.white)
            .opacity(0.92).background(.regularMaterial).ignoresSafeArea()
    }
    private func sidebarItem(_ title: String, icon: String? = nil, selected: Bool = false) -> some View {
        HStack(spacing: 13) {
            if let icon { Image(systemName: icon).font(.system(size: 18, weight: .regular)).frame(width: 21) }
            Text(title).chatNavigationFont(15, weight: .medium).lineLimit(1)
            Spacer(minLength: 0)
        }.padding(.horizontal, 20).frame(minHeight: 46).contentShape(Rectangle())
            .background(selected ? VesperTheme.ink.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 13))
    }
    private func sidebarLink(_ title: String, icon: String, target: Destination) -> some View {
        Button { navigate(target) } label: { sidebarItem(title, icon: icon, selected: destination == target) }
            .buttonStyle(.plain)
    }
    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Text("Chat").chatNavigationFont(21, weight: .semibold).frame(minHeight: 44)
            Spacer(minLength: 0)
            Button { performForSelectedBackend { searching = true } } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 19)).frame(width: 44, height: 44)
                    .vesperGlass(in: Circle(), interactive: true)
            }.accessibilityLabel("Search messages")
        }.buttonStyle(.plain).padding(.leading, 30).padding(.trailing, 18).padding(.top, 6).padding(.bottom, 12)
    }
    private func sidebarHeading(_ text: String) -> some View {
        Text(text).chatNavigationFont(15, weight: .semibold)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 20)
            .padding(.top, 26).padding(.bottom, 12)
    }
    private var contactList: some View {
        VStack(spacing: 0) {
            sidebarHeader
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    sidebarLink("Scheduled Tasks", icon: "calendar.badge.clock", target: .scheduledTasks)
                    sidebarLink("Space", icon: "books.vertical", target: .space)
                    sidebarLink("Project", icon: "folder", target: .projects)
                    if !pinnedWindows.isEmpty || organization.projects.contains(where: { organization.isPinned($0) }) {
                        sidebarHeading("Pinned")
                        ForEach(organization.projects.filter { organization.isPinned($0) }) { project in
                            Button { navigate(.project(project.id)) } label: {
                                sidebarItem(project.name, icon: project.symbol, selected: destination == .project(project.id))
                            }.buttonStyle(.plain).contextMenu { projectActions(project) }
                        }
                        ForEach(pinnedWindows) { window in organizedRow(window) }
                    }
                    sidebarHeading("Recents")
                    ForEach(otherWindows) { window in organizedRow(window) }
                }.padding(.horizontal, 10).padding(.bottom, 16)
            }.scrollIndicators(.hidden).refreshable { await refreshContacts(); activityRefreshID += 1 }
            HStack {
                Button { createChat() } label: {
                    Label("Chat", systemImage: "square.and.pencil").chatNavigationFont(15, weight: .semibold)
                        .foregroundStyle(VesperTheme.palette == .black ? Color.black : Color.white)
                        .padding(.horizontal, 20).frame(height: 46)
                        .background(VesperTheme.ink, in: Capsule())
                        .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
                }.buttonStyle(.plain).disabled(rowDisabled || chat.loadingModels)
                    .accessibilityLabel("New chat").accessibilityIdentifier("chat-new-conversation")
                Spacer(minLength: 8)
                Menu {
                    Button { showingAvatarSettings = true } label: { Label("Avatars", systemImage: "person.crop.circle") }
                    Button { showingChatPrompt = true } label: { Label("Instruction", systemImage: "doc.text") }
                    Button { performForSelectedBackend { showingFavorites = true } } label: { Label("Favorite messages", systemImage: "bookmark") }
                    Button { navigate(.activity) } label: { Label("Our days", systemImage: "calendar") }
                    Button { setDrawer(false) } label: { Label("Close sidebar", systemImage: "sidebar.left") }
                    if let onMenu { Button(action: onMenu) { Label("Vesper navigation", systemImage: "square.grid.2x2") } }
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 19)).frame(width: 44, height: 44)
                        .vesperGlass(in: Circle(), interactive: true)
                }.accessibilityLabel("Chat settings")
            }.padding(.leading, 30).padding(.trailing, 18).padding(.top, 12).padding(.bottom, 16)
        }.background { sidebarBackground }.foregroundStyle(VesperTheme.ink)
            .onAppear { contactsVisible = drawerOpen; onRootVisibilityChange(!drawerOpen && destination != .conversation) }
            .onDisappear { contactsVisible = false; onRootVisibilityChange(false) }
    }
    private var projectDirectory: some View {
        List {
            Button { editingProject = ChatProject(name: "") } label: { Label("New project", systemImage: "folder.badge.plus").frame(minHeight: 44) }
                .disabled(!selectedContacts.configured).accessibilityIdentifier("chat-new-project")
                .listRowBackground(Color.clear)
            ForEach(organization.projects) { project in projectFolder(project) }
            if organization.projects.isEmpty {
                ContentUnavailableView("Projects", systemImage: "folder", description: Text("Group conversations and give each project its own instruction."))
                    .listRowBackground(Color.clear)
            }
        }.listStyle(.plain).scrollContentBackground(.hidden).navigationTitle("Project").navigationBarTitleDisplayMode(.inline)
    }
    private func projectPage(_ project: ChatProject) -> some View {
        let windows = selectedContacts.windows.filter { organization.project(for: $0.id)?.id == project.id }
            .sorted { ($0.conversation?["updatedAt"].string ?? "") > ($1.conversation?["updatedAt"].string ?? "") }
        return ChatProjectPage(project: project, tab: $projectTab,
                               draft: Binding(get: { projectDrafts[project.id] ?? "" }, set: { projectDrafts[project.id] = $0 }),
                               canSend: !rowDisabled && !chat.loadingModels,
                               newChat: { createChat(in: project) }, send: { sendProjectMessage(project) }) {
            List {
                ForEach(windows) { window in
                    Button { enterChat(window.conversation) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(title(window)).chatNavigationFont(15, weight: .medium).lineLimit(1)
                            Text(preview(window.conversation, empty: "Start chatting"))
                                .chatNavigationFont(14, weight: .regular).foregroundStyle(VesperTheme.muted).lineLimit(1)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.vertical, 5).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(rowDisabled)
                        .contextMenu { conversationActions(window) }
                        .listRowInsets(EdgeInsets(top: 8, leading: 24, bottom: 8, trailing: 24))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                if windows.isEmpty {
                    ContentUnavailableView("Start a conversation", systemImage: "bubble.left", description: Text("Messages here use this project's instruction."))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
        } sources: {
            VStack(spacing: 0) {
                Button { editingProject = project } label: {
                    Label("Instruction", systemImage: "doc.text").chatNavigationFont()
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 24)
                }.buttonStyle(.plain)
                ChatSpaceView(api: store.api, conversationIDs: Set(windows.map(\.id)), embedded: true) { item in
                    Task {
                        if await chat.openSearchResult(.object(["id": .string(item.messageID), "conversationId": .string(item.conversationID)])) {
                            destination = .conversation; open = true; setDrawer(false)
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu { projectActions(project) } label: { Image(systemName: "ellipsis") }
            }
        }
    }
    private func sendProjectMessage(_ project: ChatProject) {
        let text = (projectDrafts[project.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !rowDisabled, !chat.loadingModels else { return }
        startingProjectChat = true
        Task {
            defer { startingProjectChat = false }
            chat.configure(store)
            guard await chat.createConversation() else { return }
            // Persist membership before the first turn so the project instruction applies immediately.
            var current = ChatOrganization.load(store.api)
            current.move(chat.conversationID, to: project.id)
            do { try current.save(store.api); organization = current }
            catch { chat.error = error.localizedDescription; return }
            chat.composer.draft = text
            projectDrafts[project.id] = ""
            captureActiveContacts(); destination = .conversation; open = true; setDrawer(false)
            _ = await chat.send(text, onAccepted: { chat.composer.draft = "" })
        }
    }

    private var contactsWithNavigation: some View {
        contactList
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $searching) {
                ChatSearchView { destination = .conversation; open = true; searching = false; setDrawer(false) }
                    .toolbar(.visible, for: .navigationBar)
            }
            .navigationDestination(isPresented: $showingFavorites) {
                ChatFavoritesView { destination = .conversation; open = true; showingFavorites = false; setDrawer(false) }
                    .toolbar(.visible, for: .navigationBar)
            }
            .task {
                chat.configure(store)
                captureActiveContacts(); reloadOrganization()
                if chatTabSelected { restoreLastWindow() }
                else if !openedOnce, workspace?.isOpen(store.activeBackend) == true {
                    open = true
                    if chat.messages.isEmpty { enterChat(dismissSidebar: false) }
                }
                if sideBySide && !store.token.isEmpty && !open { enterChat(dismissSidebar: false) }
                if !store.token.isEmpty { await refreshContacts() }
                if !openedOnce { openedOnce = true }
            }
            .onChange(of: chatTabSelected) { _, selected in
                if selected { restoreLastWindow() }
            }
            .onChange(of: open || searching || showingFavorites) { _, detail in onRootVisibilityChange(!drawerOpen && destination != .conversation) }
            .onChange(of: open) { _, isOpen in
                workspace?.setOpen(isOpen, backend: store.activeBackend)
                if !isOpen {
                    openingTask?.cancel(); openingTask = nil; loadingChat = false
                    Task { await chat.loadConversations(); captureActiveContacts() }
                }
            }
            .onChange(of: chat.conversations) { _, _ in captureActiveContacts() }
            .onChange(of: chat.conversationID) { _, id in
                if !id.isEmpty, !chat.messages.isEmpty || chat.conversations.contains(where: { $0.id == id }) {
                    windowSelection.wrappedValue = id
                    ChatWindowMemory.remember(id, api: store.api)
                }
            }
            .onChange(of: store.documents["profile"]) { _, _ in captureActiveContacts() }
            .onChange(of: selectedContacts.scope) { _, _ in reloadOrganization() }
            .onChange(of: store.token) { _, _ in
                chat.configure(store); captureActiveContacts()
                Task { await refreshContacts() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("VesperConversationOpened"))) { _ in destination = .conversation; open = true; setDrawer(false) }
    }

    private var contactsWithDialogs: some View {
        contactsWithNavigation
            .sheet(isPresented: $showingAvatarSettings, onDismiss: { captureActiveContacts() }) {
                NavigationStack { ChatAvatarSettingsView().environmentObject(store)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingAvatarSettings = false } } }
                }
            }
            .sheet(isPresented: $showingChatPrompt, onDismiss: reloadOrganization) {
                ChatPromptEditor(api: store.api, contact: agentName + " · " + selectedBackend.title)
            }
            .sheet(item: $editingProject) { project in
                ChatProjectEditor(project: project, isNew: !organization.projects.contains(where: { $0.id == project.id })) { updated in
                    var current = ChatOrganization.load(store.api)
                    if let index = current.projects.firstIndex(where: { $0.id == updated.id }) { current.projects[index] = updated }
                    else { current.projects.append(updated) }
                    try current.save(store.api); organization = current
                    expandedProjects.insert(updated.id)
                }
            }
            .confirmationDialog("Remove project?", isPresented: Binding(get: { deletingProject != nil }, set: { if !$0 { deletingProject = nil } })) {
                Button("Remove project", role: .destructive) {
                    if let project = deletingProject { editOrganization { $0.removeProject(project.id) } }
                    deletingProject = nil
                }
                Button("Cancel", role: .cancel) { deletingProject = nil }
            } message: { Text("The project and its instruction will be removed. Its conversations stay in Chats.") }
            .confirmationDialog("Delete this conversation?", isPresented: Binding(get: { deletingConversation != nil }, set: { if !$0 { deletingConversation = nil } }), titleVisibility: .visible) {
                Button("Delete conversation", role: .destructive) {
                    guard let item = deletingConversation else { return }
                    deletingConversation = nil
                    deleting = true
                    Task {
                        defer { deleting = false }
                        await chat.removeConversation(item)
                    }
                }
                Button("Cancel", role: .cancel) { deletingConversation = nil }
            } message: {
                Text((deletingConversation?["title"].string ?? "") + "\n" + String((deletingConversation?["preview"].string ?? "").prefix(100)) + "\n\nThis deletes this conversation. Please check the preview before confirming.")
            }
            .alert("Rename chat title", isPresented: Binding(get: { renamingConversation != nil }, set: { if !$0 { renamingConversation = nil } })) {
                TextField("Name", text: $conversationTitle)
                Button("Save") {
                    guard let item = renamingConversation else { return }
                    let title = conversationTitle
                    renamingConversation = nil; renaming = true
                    Task { defer { renaming = false }; await chat.renameConversation(item, title: title) }
                }.disabled(conversationTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { renamingConversation = nil }
            } message: {
                Text("Changes this chat’s title. To update the name throughout Vesper, use Edit contact name on the Avatars page.")
            }
            .alert("Chat", isPresented: Binding(get: { !open && chat.error != nil }, set: { if !$0 { chat.error = nil } })) {
                Button("OK") { chat.error = nil }
            } message: { Text(chat.error ?? "") }
    }

    private var pinnedWindows: [ChatConversationWindow] {
        selectedContacts.windows.filter { organization.pinned.contains($0.id) }
    }
    private var otherWindows: [ChatConversationWindow] {
        selectedContacts.windows.filter { !organization.pinned.contains($0.id) }.sorted {
            ($0.conversation?["updatedAt"].string ?? "") > ($1.conversation?["updatedAt"].string ?? "")
        }
    }
    private func reloadOrganization() { organization = ChatOrganization.load(store.api) }
    private func editOrganization(_ change: (inout ChatOrganization) -> Void) {
        var current = ChatOrganization.load(store.api)
        change(&current)
        do { try current.save(store.api); organization = current }
        catch { chat.error = error.localizedDescription }
    }
    private func createChat(in project: ChatProject? = nil) {
        performForSelectedBackend {
            if await chat.createConversation() {
                if let project { editOrganization { $0.move(chat.conversationID, to: project.id) } }
                captureActiveContacts(); destination = .conversation; open = true; setDrawer(false)
            }
        }
    }
    private func title(_ window: ChatConversationWindow) -> String {
        let saved = window.conversation?["title"].string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? window.title : saved
    }
    private func organizedRow(_ window: ChatConversationWindow) -> some View {
        Button { enterChat(window.conversation) } label: {
            sidebarItem(title(window), icon: organization.pinned.contains(window.id) ? "bubble.left" : nil,
                        selected: destination == .conversation && open && chat.conversationID == window.id)
        }.buttonStyle(.plain).disabled(rowDisabled)
            .contextMenu { conversationActions(window) }
    }
    @ViewBuilder private func conversationActions(_ window: ChatConversationWindow) -> some View {
        if let item = window.conversation {
            Button { editOrganization { if !$0.pinned.insert(item.id).inserted { $0.pinned.remove(item.id) } } } label: {
                Label(organization.pinned.contains(item.id) ? "Unpin" : "Pin", systemImage: organization.pinned.contains(item.id) ? "pin.slash" : "pin")
            }
            Button { conversationTitle = item["title"].string; renamingConversation = item } label: { Label("Rename chat title", systemImage: "pencil") }
            Menu {
                Button { editOrganization { $0.move(item.id, to: nil) } } label: { Label("Outside projects", systemImage: "bubble.left") }
                ForEach(organization.projects) { project in
                    Button { editOrganization { $0.move(item.id, to: project.id) }; expandedProjects.insert(project.id) } label: {
                        Label(project.name, systemImage: organization.project(for: item.id)?.id == project.id ? "checkmark" : "folder")
                    }
                }
            } label: { Label("Move to project", systemImage: "folder") }
            Button(role: .destructive) { deletingConversation = item } label: { Label("Delete conversation", systemImage: "trash") }
        }
    }
    private func projectFolder(_ project: ChatProject) -> some View {
        HStack(spacing: 4) {
            Button { navigate(.project(project.id)) } label: {
                HStack(spacing: 12) {
                    Image(systemName: project.symbol).font(.system(size: 20)).frame(width: 24)
                    Text(project.name).chatNavigationFont().lineLimit(1)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu { projectActions(project) } label: { Image(systemName: "ellipsis").frame(width: 36, height: 44) }
                .accessibilityLabel("Settings for " + project.name)
        }.foregroundStyle(VesperTheme.ink).contextMenu { projectActions(project) }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }
    @ViewBuilder private func projectActions(_ project: ChatProject) -> some View {
        Button { editOrganization { $0.togglePin(project) } } label: {
            Label(organization.isPinned(project) ? "Unpin" : "Pin", systemImage: organization.isPinned(project) ? "pin.slash" : "pin")
        }
        Button { createChat(in: project) } label: { Label("New chat", systemImage: "square.and.pencil") }
            .disabled(rowDisabled || chat.loadingModels)
        Button { editingProject = project } label: { Label("Name, icon & instruction", systemImage: "pencil") }
        Button(role: .destructive) { deletingProject = project } label: { Label("Remove project", systemImage: "folder.badge.minus") }
    }

    private func updateWelcomeLine() {
        welcomeLine = ChatWelcomeLines.next(after: welcomeLine)
    }

    private func restoreLastWindow() {
        guard !store.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        chat.configure(store)
        if loadingChat || chat.busy || chat.showingCachedHistory || !chat.messages.isEmpty {
            destination = .conversation; open = true; setDrawer(false, animated: false)
            return
        }
        let legacy = windowSelection.wrappedValue
        let knownLegacy = selectedContacts.conversations.contains(where: { $0.id == legacy }) ? legacy : nil
        let last = ChatWindowMemory.last(api: store.api) ?? knownLegacy
        if let last, !last.isEmpty {
            let item = selectedContacts.conversations.first { $0.id == last } ?? .object(["id": .string(last)])
            enterChat(item, dismissSidebar: false)
        } else { enterChat(dismissSidebar: false) }
        if open { setDrawer(false, animated: false) }
    }

    private func enterChat(_ item: JSONValue? = nil, dismissSidebar: Bool = true) {
        guard !store.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            chat.error = "\(store.activeBackend.title) connection is not configured."
            return
        }
        chat.configure(store)
        if (item?.id ?? mainConversationID) == chat.conversationID,
           !chat.messages.isEmpty, !chat.showingCachedHistory {
            destination = .conversation; open = true; loadingChat = false
            if dismissSidebar { setDrawer(false) }
            return
        }
        guard !rowDisabled else { return }
        chat.configure(store)
        destination = .conversation
        if let item, !item.id.isEmpty { ChatWindowMemory.remember(item.id, api: store.api) }
        let previewVisible = chat.previewConversation(item?.id)
        loadingChat = !previewVisible
        open = true
        if dismissSidebar { setDrawer(false) }
        openingTask = Task {
            let opened: Bool
            if let item { opened = await chat.open(item) }
            else { opened = await chat.openMainRoom() }
            guard !Task.isCancelled else { return }
            openingTask = nil
            loadingChat = false
            if !opened && !chat.showingCachedHistory { open = false }
        }
    }

    private var agentName: String {
        selectedContacts.agentName
    }
    private func captureActiveContacts() {
        backendContacts.capture(store.activeBackend, api: store.api, profile: store.document("profile"), conversations: chat.conversations(for: store.api))
    }
    private func refreshContacts() async {
        await chat.loadConversations()
        guard !Task.isCancelled else { return }
        captureActiveContacts()
    }
    private func performForSelectedBackend(_ action: @escaping @MainActor () async -> Void) {
        guard !rowDisabled else { return }
        guard !store.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            chat.error = "\(store.activeBackend.title) connection is not configured."
            return
        }
        Task { await action() }
    }
    private func preview(_ item: JSONValue?, empty: String) -> String {
        guard let item else { return empty }
        let text = item["preview"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? empty : text
    }
    private func conversationRowContent(_ item: JSONValue?, title: String, emptyPreview: String, contacts: ChatBackendContactSnapshot, showBackend: Bool = false) -> some View {
        HStack(spacing: 13) {
            ChatListAvatar(source: contacts.profile["agentAvatar"].string, baseURL: contacts.baseURL)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    if showBackend {
                        Text(contacts.backend == .vps ? "VPS" : "MAC").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 3).background(VesperTheme.ink.opacity(0.1), in: Capsule())
                    }
                    Spacer(minLength: 4)
                    if let item {
                        Text(ChatPresentation.time(item["updatedAt"].string.isEmpty ? item["createdAt"].string : item["updatedAt"].string))
                            .font(.caption).foregroundStyle(VesperTheme.muted)
                    }
                }
                Text(preview(item, empty: emptyPreview))
                    .font(.subheadline).foregroundStyle(VesperTheme.muted).lineLimit(1)
            }
        }
    }
}

struct ChatConversationWindow: Identifiable {
    let id: String
    let conversation: JSONValue?
    let title: String
    let isMain: Bool
}

struct ChatBackendContactSnapshot {
    let backend: VesperBackend
    let scope: String
    let baseURL: String
    var profile: JSONValue
    var conversations: [JSONValue]
    var configured: Bool
    var error: String?
    var mainID: String {
        let saved = profile["mainConversationId"].string
        return saved.isEmpty ? conversations.first?.id ?? "" : saved
    }
    var mainConversation: JSONValue? { conversations.first { $0.id == mainID } }
    var agentName: String {
        let name = profile["agentName"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Rowan" : name
    }
    var windows: [ChatConversationWindow] {
        var seen: Set<String> = [mainID]
        return [ChatConversationWindow(id: mainID.isEmpty ? "unconfigured-main" : mainID,
                                       conversation: mainConversation, title: agentName, isMain: true)]
            + conversations.compactMap { room in
                guard !room.id.isEmpty, seen.insert(room.id).inserted else { return nil }
                let title = room["title"].string.trimmingCharacters(in: .whitespacesAndNewlines)
                return ChatConversationWindow(id: room.id, conversation: room, title: title.isEmpty ? agentName : title, isMain: false)
            }
    }
}

/// Read-only contact previews. Viewing the other card never retargets ChatSession.
@MainActor final class ChatBackendContacts: ObservableObject {
    @Published private(set) var snapshots: [VesperBackend: ChatBackendContactSnapshot] = [:]
    private var revisions: [VesperBackend: UUID] = [:]
    private var clients: [VesperBackend: APIClient] = [:]
    private let cacheRoot: URL?
    private let disk: LocalDocumentDisk
    private let request: (APIClient, String, Bool) async throws -> JSONValue
    init(cacheRoot: URL? = nil, disk: LocalDocumentDisk = LocalDocumentDisk(),
         request: @escaping (APIClient, String, Bool) async throws -> JSONValue = { try await $0.request($1, history: $2) }) {
        self.cacheRoot = cacheRoot; self.disk = disk; self.request = request
    }
    func snapshot(_ backend: VesperBackend) -> ChatBackendContactSnapshot {
        snapshots[backend] ?? ChatBackendContactSnapshot(backend: backend, scope: "", baseURL: BackendConnection.load(backend).baseURL,
                                                       profile: .null, conversations: [], configured: false)
    }
    // The visible backend already has a live AppStore. Use it on the first render
    // and after edits, rather than waiting for a separate preview cache to catch up.
    func activeSnapshot(_ backend: VesperBackend, api: APIClient, profile: JSONValue,
                        conversations: [JSONValue]) -> ChatBackendContactSnapshot {
        let cached = snapshots[backend].flatMap { $0.scope == scope(api) ? $0 : nil }
        return ChatBackendContactSnapshot(backend: backend, scope: scope(api), baseURL: api.baseURL,
                                          profile: profile == .null ? (cached?.profile ?? .null) : profile,
                                          conversations: conversations.isEmpty ? (cached?.conversations ?? []) : conversations,
                                          configured: !api.token.isEmpty, error: cached?.error)
    }
    func client(_ backend: VesperBackend) -> APIClient? { clients[backend] }
    private func file(_ api: APIClient) -> URL? { ChatRecentCache.directory(api: api, root: cacheRoot)?.appendingPathComponent("contacts.json") }
    private func scope(_ api: APIClient) -> String { ChatRecentCache.directory(api: api, root: cacheRoot)?.lastPathComponent ?? "" }
    func prepare(_ backend: VesperBackend, api: APIClient) {
        clients[backend] = api
        guard snapshots[backend]?.scope != scope(api) else { return }
        revisions[backend] = UUID()
        let cached = file(api).flatMap { url -> JSONValue? in
            guard let data = try? Data(contentsOf: url), data.count <= 1_000_000 else { return nil }
            return try? JSONDecoder().decode(JSONValue.self, from: data)
        }
        let local = try? disk.load(api)
        snapshots[backend] = ChatBackendContactSnapshot(backend: backend, scope: scope(api), baseURL: api.baseURL,
                                                       profile: local?.documents["profile"] ?? cached?["profile"] ?? .null,
                                                       conversations: cached?["conversations"].array ?? [], configured: !api.token.isEmpty)
    }
    func capture(_ backend: VesperBackend, api: APIClient, profile: JSONValue, conversations: [JSONValue]) {
        clients[backend] = api
        revisions[backend] = UUID()
        snapshots[backend] = ChatBackendContactSnapshot(backend: backend, scope: scope(api), baseURL: api.baseURL,
                                                       profile: profile, conversations: conversations, configured: !api.token.isEmpty)
        save(backend, api: api)
    }
    func refresh(_ backend: VesperBackend, api: APIClient) async {
        prepare(backend, api: api)
        guard !api.token.isEmpty else { return }
        let revision = UUID(); revisions[backend] = revision
        do {
            async let profile = request(api, "/api/state?key=profile", false)
            async let listing = request(api, "/conversations", true)
            let (state, rooms) = try await (profile, listing)
            try Task.checkCancellation()
            guard revisions[backend] == revision, snapshots[backend]?.scope == scope(api) else { return }
            guard case .object = state["value"], case .array(let conversations) = rooms["conversations"] else {
                throw ServiceError(message: "Contact list unavailable.")
            }
            snapshots[backend] = ChatBackendContactSnapshot(backend: backend, scope: scope(api), baseURL: api.baseURL,
                                                           profile: state["value"], conversations: conversations, configured: true)
            save(backend, api: api)
        } catch {
            guard revisions[backend] == revision, !Task.isCancelled, !(error is CancellationError) else { return }
            snapshots[backend]?.error = error.localizedDescription
        }
    }
    private func save(_ backend: VesperBackend, api: APIClient) {
        guard let snapshot = snapshots[backend], let file = file(api) else { return }
        let value: JSONValue = .object(["profile": snapshot.profile, "conversations": .array(snapshot.conversations)])
        guard let data = try? JSONEncoder().encode(value), data.count <= 1_000_000 else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

struct ChatConversationDeck<Content: View>: View {
    let windows: [ChatConversationWindow]
    @Binding var selected: String
    @ViewBuilder var card: (ChatConversationWindow) -> Content
    @GestureState private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var index: Int { windows.firstIndex { $0.id == selected } ?? 0 }
    private func flip(_ direction: Int) {
        guard windows.count > 1 else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.85)) {
            selected = windows[(index + direction + windows.count) % windows.count].id
        }
    }
    var body: some View {
        if !windows.isEmpty {
        VStack(spacing: 5) {
        ZStack {
            ForEach(Array(1..<min(windows.count, 3)).reversed(), id: \.self) { depth in
                card(windows[(index + depth) % windows.count]).mask(alignment: .top) { Rectangle().frame(height: 14) }
                    .scaleEffect(x: 1 - CGFloat(depth) * 0.05, y: 0.95, anchor: .top).offset(y: -CGFloat(depth) * 12)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            card(windows[index]).id(windows[index].id).offset(y: drag)
        }.padding(.top, windows.count > 2 ? 28 : windows.count > 1 ? 18 : 0).contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 14)
                .updating($drag) { value, state, _ in
                    if abs(value.translation.height) > abs(value.translation.width) * 1.25 {
                        state = min(12, max(-12, value.translation.height / 4))
                    }
                }
                .onEnded { value in
                    if abs(value.translation.height) >= 28, abs(value.translation.height) > abs(value.translation.width) * 1.25 {
                        flip(value.translation.height < 0 ? 1 : -1)
                    }
                }, including: windows.count > 1 ? .all : .none)
            if windows.count > 1 {
                Text("\(index + 1) / \(windows.count)").font(.caption2).monospacedDigit().foregroundStyle(VesperTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 10).accessibilityHidden(true)
            }
        }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Conversation windows")
            .accessibilityValue("\(index + 1) of \(windows.count)")
            .accessibilityAction(named: Text("Next conversation")) { flip(1) }
            .accessibilityAction(named: Text("Previous conversation")) { flip(-1) }
            .accessibilityIdentifier("chat-conversation-deck")
        }
    }
}

struct ChatFavoritesView: View {
    @EnvironmentObject private var chat: ChatSession
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var selected: () -> Void
    @State private var query = ""
    @State private var error = ""
    @State private var opening = false

    private var favorites: [JSONValue] {
        store.document("favorites").array.filter {
            query.isEmpty || $0["content"].string.localizedCaseInsensitiveContains(query)
                || $0["conversationTitle"].string.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            if favorites.isEmpty && error.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No favorite messages yet" : "No matching messages",
                                       systemImage: "bookmark", description: Text(query.isEmpty ? "Bookmark a message in chat to keep it here." : "Try another search."))
                    .listRowBackground(Color.clear)
            }
            ForEach(favorites) { item in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(item["role"].string == "user" ? "You" : store.agentDisplayName)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(ChatPresentation.time(item["createdAt"].string)).font(.caption).foregroundStyle(VesperTheme.muted)
                    }
                    ChatMarkdownText(content: item["content"].string).font(.subheadline).lineLimit(6)
                    Button {
                        opening = true
                        Task {
                            let opened = await chat.openSearchResult(.object([
                                "id": item["metadata"]["sourceMessageId"].string.isEmpty ? item["messageId"] : item["metadata"]["sourceMessageId"], "conversationId": item["conversationId"]
                            ]))
                            opening = false
                            if opened { dismiss(); selected() }
                            else { error = chat.error ?? "Could not open this message."; chat.error = nil }
                        }
                    } label: { Label("Open message", systemImage: "arrow.up.right") }
                        .font(.caption.weight(.semibold)).disabled(opening || chat.busy || chat.callActive)
                }
                .padding(.vertical, 7)
                .swipeActions {
                    Button(role: .destructive) { Task { _ = await store.remove("favorites", id: item.id) } } label: {
                        Label("Remove favorite", systemImage: "bookmark.slash")
                    }.disabled(store.saving)
                }
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).transparentNavigationTop()
        .background { Background() }
        .navigationTitle("Favorites").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search favorites")
        .refreshable { await store.refresh() }
    }
}

private extension View {
    func contactGlassSurface(verticalPadding: CGFloat = 15) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return self
            .padding(.horizontal, 16).padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
.vesperGlass(in: shape, interactive: true)
    }
}

private struct ChatListAvatar: View {
    let source: String
    let baseURL: String
    var size: CGFloat = 52
    var body: some View {
        Group {
            if source.hasPrefix("data:image/"),
               let comma = source.firstIndex(of: ","),
               let data = Data(base64Encoded: String(source[source.index(after: comma)...])),
               let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if !source.isEmpty,
                      let url = URL(string: source, relativeTo: URL(string: baseURL))?.absoluteURL,
                      url.scheme == "https" {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
            } else { placeholder }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    }
    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(VesperTheme.muted.opacity(0.19))
            Image(systemName: "person.fill").font(.system(size: 22)).foregroundStyle(VesperTheme.muted)
        }
    }
}
struct ChatSearchView: View {
    @EnvironmentObject private var chat: ChatSession
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var selected: () -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var scope = "All chats"
    @State private var results: [JSONValue] = []
    @State private var busy = false
    @State private var error = ""
    @State private var hasMore = false
    @State private var searchNotice = ""
    var body: some View {
        VStack(spacing: 12) {
            // Keep search controls outside the results so they never scroll away.
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(VesperTheme.muted)
                    TextField("Search messages", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.search).focused($searchFocused)
                        .accessibilityIdentifier("chat-search-field")
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(VesperTheme.muted)
                        }.buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 16).frame(minHeight: 46)
                .background(.regularMaterial, in: Capsule())
                Picker("Search in", selection: $scope) {
                    Text("All chats").tag("All chats")
                    Text("This chat").tag("This chat")
                }.pickerStyle(.segmented)
            }.padding(.horizontal, 20).padding(.top, 8)
            List {
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            if !searchNotice.isEmpty { Text(searchNotice).font(.caption).foregroundStyle(VesperTheme.muted) }
            if busy { ProgressView() }
            ForEach(results) { message in
                Button { Task {
                    guard await chat.openSearchResult(message) else { error = chat.error ?? "Could not open this message."; chat.error = nil; return }
                    dismiss(); selected()
                } } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message["title"].string).font(.headline)
                        Text(highlightedSnippet(message["content"].string)).font(.subheadline).lineLimit(4)
                        Text(ChatPresentation.time(message["createdAt"].string)).font(.caption).foregroundStyle(VesperTheme.muted)
                    }
                }.disabled(chat.busy)
            }
            if hasMore { Button("More results") { Task { await search(more: true) } }.disabled(busy) }
            if !busy && results.isEmpty && !query.isEmpty && error.isEmpty && searchNotice.isEmpty { Text("No matching messages.").foregroundStyle(VesperTheme.muted) }
            }.scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively)
        }
        .transparentNavigationTop().background { Background() }
        .navigationTitle("Search").navigationBarTitleDisplayMode(.inline)
        .task { searchFocused = true }
        .task(id: query + "\u{0}" + scope) {
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            await search()
        }
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: scope) { _, _ in Task { await search() } }
    }
    private func snippet(_ text: String) -> String {
        guard let range = text.range(of: query, options: .caseInsensitive) else { return String(text.prefix(240)) }
        let start = text.index(range.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        return (start > text.startIndex ? "…" : "") + String(text[start...].prefix(240))
    }
    private func highlightedSnippet(_ text: String) -> AttributedString {
        var result = AttributedString(snippet(text))
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty, let range = result.range(of: term, options: .caseInsensitive) {
            result[range].foregroundColor = .blue
            result[range].font = .body.bold()
        }
        return result
    }
    private func search(more: Bool = false) async {
        if more && busy { return }
        let requested = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedScope = scope
        busy = true
        defer { if requested == query.trimmingCharacters(in: .whitespacesAndNewlines), requestedScope == scope { busy = false } }
        if !more { results = []; hasMore = false; error = ""; searchNotice = "" }
        guard !requested.isEmpty else { results = []; hasMore = false; error = ""; searchNotice = ""; return }
        do {
            var params = URLComponents(); params.queryItems = [URLQueryItem(name: "q", value: requested), URLQueryItem(name: "conversationId", value: scope == "This chat" ? chat.conversationID : ""), URLQueryItem(name: "offset", value: String(more ? results.count : 0))]
            let response = try await store.api.request("/search?" + (params.percentEncodedQuery ?? ""), history: true)
            guard requested == query.trimmingCharacters(in: .whitespacesAndNewlines), requestedScope == scope else { return }
            results = more ? results + response["results"].array : response["results"].array
            hasMore = response["hasMore"].bool; error = ""; searchNotice = ""
        } catch let failure as ServiceError where failure.statusCode == 404 {
            guard !Task.isCancelled, requested == query.trimmingCharacters(in: .whitespacesAndNewlines), requestedScope == scope else { return }
            await legacySearch(requested, scope: requestedScope)
        } catch {
            guard !Task.isCancelled, requested == query.trimmingCharacters(in: .whitespacesAndNewlines), requestedScope == scope else { return }
            self.error = error.localizedDescription
        }
    }
    private func legacySearch(_ requested: String, scope requestedScope: String) async {
        do {
            let response = try await store.api.request("/conversations", history: true)
            let conversations = response["conversations"].array.filter { requestedScope != "This chat" || $0.id == chat.conversationID }
            var matches: [JSONValue] = []
            var limited = false
            var failed = 0
            for conversation in conversations {
                guard requested == query.trimmingCharacters(in: .whitespacesAndNewlines), requestedScope == scope else { return }
                let page: JSONValue
                do { page = try await store.api.request("/conversations/" + conversation.id, history: true) }
                catch { failed += 1; continue }
                let messages = page["messages"].array
                if messages.count >= 1000 || page["hasMore"].bool { limited = true }
                for message in messages where message["content"].string.localizedCaseInsensitiveContains(requested) {
                    var fields = message.object
                    fields["conversationId"] = .string(conversation.id)
                    fields["title"] = conversation["title"]
                    matches.append(.object(fields))
                }
            }
            guard requested == query.trimmingCharacters(in: .whitespacesAndNewlines), requestedScope == scope else { return }
            results = matches; hasMore = false; error = ""
            if failed > 0 {
                searchNotice = "\(failed) conversation(s) could not be read. These results are incomplete."
                return
            }
            searchNotice = limited ? "Compatibility search: the server may return only the first 1,000 messages per chat. Update the history service for complete search." : "Compatibility search of saved chats. Update the history service to enable the dedicated search endpoint."
        } catch { self.error = "Could not search saved history: " + error.localizedDescription }
    }
}
