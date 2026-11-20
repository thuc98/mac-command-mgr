import AppKit
import CommandManagerCore
import SwiftUI

struct ServiceFormView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var popoverController: PopoverController
    let editingID: UUID?
    @Binding var route: Route
    var prefill: ServiceDraft? = nil

    @State private var draft = ServiceDraft()
    @State private var loaded = false
    @State private var saveError: String?
    @State private var contentHeight: CGFloat = 0
    /// The form grows with its fields up to this height, then scrolls.
    static let maxFieldsHeight: CGFloat = 460

    private var issues: [ValidationIssue] { model.validate(draft, editing: editingID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(editingID == nil ? ((prefill?.command ?? "").isEmpty ? "Add command" : "Add dropped command") : "Edit command").font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    field("Name", .displayName) {
                        TextField("e.g. API server", text: $draft.displayName)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Name")
                    }
                    field("Command", .command) {
                        TextEditor(text: $draft.command)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 64)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
                            .accessibilityLabel("Command")
                    }
                    field("Working folder", .workingDirectory) {
                        HStack {
                            TextField("~/projects/my-app", text: $draft.workingDirectory)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Working folder")
                            Button("Choose…", action: chooseFolder)
                        }
                    }
                    field("Environment (KEY=VALUE per line)", .environment) {
                        TextEditor(text: $draft.environmentText)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 52)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
                            .accessibilityLabel("Environment variables")
                    }
                    if !model.layout.groups.isEmpty {
                        Picker("Group", selection: $draft.groupID) {
                            Text("None").tag(UUID?.none)
                            ForEach(model.layout.groups) { g in Text(g.name).tag(UUID?.some(g.id)) }
                        }
                        .frame(maxWidth: 260)
                    }
                    Toggle("Enabled", isOn: $draft.isEnabled)
                    Toggle("Start when app opens", isOn: $draft.autoStart)
                    Toggle("Restart on exit or crash", isOn: $draft.restartOnExit)
                        .help("Waits 1 s, doubling up to 1 min between tries")
                    if let saveError {
                        Text(saveError).font(.caption).foregroundColor(.red).textSelection(.enabled)
                    }
                }
                .toggleStyle(.checkbox)
                .padding(12)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: FormHeightKey.self, value: proxy.size.height)
                })
            }
            .frame(height: contentHeight > 0 ? min(contentHeight, Self.maxFieldsHeight) : Self.maxFieldsHeight)
            .onPreferenceChange(FormHeightKey.self) { contentHeight = $0 }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { route = editingID.map(Route.detail) ?? .list }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!issues.isEmpty)
            }
            .padding(12)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let id = editingID, let existing = model.service(id) { draft = ServiceDraft(existing) }
            else if let prefill { draft = prefill }
        }
    }

    @ViewBuilder
    private func field<Content: View>(_ title: String, _ key: ValidationField,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium))
            content()
            if let issue = issues.first(where: { $0.field == key }), showIssue(key) {
                Label(issue.message, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundColor(.red)
                    .accessibilityLabel("\(title) error: \(issue.message)")
            }
        }
    }

    /// Don't shout "required" at an untouched empty form.
    private func showIssue(_ key: ValidationField) -> Bool {
        switch key {
        case .displayName: return !draft.displayName.isEmpty || editingID != nil
        case .command: return !draft.command.isEmpty || editingID != nil
        default: return true
        }
    }

    private func chooseFolder() {
        popoverController.withPinnedPopover { done in
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Choose"
            if let current = ServiceValidator.normalizedDirectory(draft.workingDirectory) {
                panel.directoryURL = URL(fileURLWithPath: current)
            }
            panel.begin { response in
                if response == .OK, let url = panel.url { draft.workingDirectory = url.path }
                done()
            }
        }
    }

    private func save() {
        switch model.save(draft, editing: editingID) {
        case .success(let definition):
            route = .detail(definition.id)
        case .failure(let error as ValidationFailure):
            saveError = error.issues.map(\.message).joined(separator: "\n")
        case .failure(let error):
            saveError = error.localizedDescription
        }
    }
}

private struct FormHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
