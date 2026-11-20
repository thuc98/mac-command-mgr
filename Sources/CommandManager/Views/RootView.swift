import AppKit
import CommandManagerCore
import SwiftUI
import UniformTypeIdentifiers

enum Route: Equatable {
    case list
    case detail(UUID)
    case add
    /// Add form prefilled from a dropped file or folder.
    case addPrefilled(ServiceDraft)
    case edit(UUID)
    case settings
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var popoverController: PopoverController
    @State private var route: Route = .list
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if let banner = model.banner {
                BannerView(message: banner) { model.banner = nil }
            }
            Group {
                switch route {
                case .list:
                    ServiceListView(route: $route)
                case .detail(let id):
                    if model.service(id) != nil {
                        ServiceDetailView(serviceID: id, route: $route)
                    } else {
                        ServiceListView(route: $route)
                    }
                case .add:
                    ServiceFormView(editingID: nil, route: $route)
                case .addPrefilled(let draft):
                    ServiceFormView(editingID: nil, route: $route, prefill: draft)
                        .id(draft.workingDirectory + "|" + draft.command + "|" + draft.displayName)
                case .edit(let id):
                    ServiceFormView(editingID: id, route: $route)
                case .settings:
                    SettingsView(route: $route)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: isCompact ? nil : .infinity)
        }
        // List and forms size to their content; the detail view (with its log) keeps full height.
        .frame(width: 440, height: isCompact ? nil : 560)
        .fixedSize(horizontal: false, vertical: isCompact)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: PopoverHeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(PopoverHeightKey.self) { popoverController.setContentHeight($0) }
        .overlay(dropOverlay)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            FileDrop.loadURL(provider) { url in popoverController.handleDrop(url, model: model) }
            return true
        }
        .onReceive(popoverController.$pendingDraft.compactMap { $0 }) { draft in
            route = .addPrefilled(draft)
            popoverController.pendingDraft = nil
        }
    }

    private var isCompact: Bool {
        switch route {
        case .list, .add, .addPrefilled, .edit, .settings: return true
        case .detail: break
        }
        if case .detail(let id) = route, model.service(id) == nil { return true }
        return false
    }

    @ViewBuilder private var dropOverlay: some View {
        if dropTargeted {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12))
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                VStack(spacing: 6) {
                    Image(systemName: "plus.rectangle.on.folder").font(.largeTitle)
                    Text("Drop to add as a command").font(.headline)
                }
            }
            .padding(6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct PopoverHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

enum FileDrop {
    /// Reads a file URL from a drag item and calls back on the main thread.
    static func loadURL(_ provider: NSItemProvider, _ completion: @escaping @MainActor (URL) -> Void) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else if let u = item as? URL { url = u }
            guard let url, url.isFileURL else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(url) } }
        }
    }
}

struct BannerView: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy error")
                .accessibilityLabel("Copy error details")
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss error")
        }
        .padding(10)
        .background(Color.orange.opacity(0.15))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Error: \(message)")
    }
}

/// Status shown as symbol + text so it never depends on color alone.
struct StatusBadge: View {
    let state: RuntimeState

    var body: some View {
        Label(state.label, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.medium))
            .foregroundColor(color)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Status: \(state.label)")
    }

    var symbol: String {
        switch state {
        case .stopped: return "stop.circle"
        case .starting: return "hourglass"
        case .running: return "play.circle.fill"
        case .stopping: return "hourglass.bottomhalf.filled"
        case .exited: return "checkmark.circle"
        case .failed: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var color: Color {
        switch state {
        case .running: return .green
        case .failed: return .red
        case .starting, .stopping: return .orange
        case .unknown: return .purple
        case .stopped, .exited: return .secondary
        }
    }
}

enum Formatters {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()
}
