import AppKit
import CommandManagerCore
import SwiftUI

/// Applies the stored light/dark choice to every window (popover, log viewers, alerts).
@MainActor
enum AppearanceController {
    static func apply(_ preference: AppearancePreference) {
        switch preference {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// App settings shown inside the popover: appearance, open at login and storage.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Binding var route: Route
    @AppStorage(AppearancePreference.defaultsKey) private var appearance: AppearancePreference = .system

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { route = .list } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
            .overlay(Text("Settings").font(.headline).accessibilityAddTraits(.isHeader))
            .padding(12)
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                section("Appearance") {
                    HStack(spacing: 8) {
                        ForEach(AppearancePreference.allCases) { option in
                            AppearanceTile(option: option, isSelected: appearance == option) {
                                appearance = option
                            }
                        }
                    }
                    .padding(10)
                }

                section("General") {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Open at login")
                                Text(loginCaption)
                                    .font(.caption)
                                    .foregroundColor(isUnavailable ? .orange : .secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 12)
                            Toggle("Open at login", isOn: Binding(
                                get: { model.loginItemStatus == .enabled || model.loginItemStatus == .requiresApproval },
                                set: { model.setOpenAtLogin($0) }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(isUnavailable)
                            .accessibilityHint(model.loginItemStatus.label)
                        }
                        .padding(10)
                        if model.loginItemStatus == .requiresApproval {
                            Divider().padding(.leading, 10)
                            HStack {
                                Text("Approve Command Manager in System Settings to finish.")
                                    .font(.caption).foregroundColor(.secondary)
                                Spacer()
                                Button("Open Login Items", action: openLoginItems)
                                    .controlSize(.small)
                            }
                            .padding(10)
                        }
                    }
                }

                section("Storage") {
                    VStack(spacing: 0) {
                        folderRow("Logs", systemImage: "doc.text", url: model.paths.logsDirectory,
                                  hint: "Opens the folder with every command's log files in Finder")
                        Divider().padding(.leading, 36)
                        folderRow("Data", systemImage: "externaldrive", url: model.paths.root,
                                  hint: "Opens the folder with Command Manager's settings and commands in Finder")
                    }
                }

                HStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                    Text("Command Manager \(version)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(12)
        }
        .onChange(of: appearance) { AppearanceController.apply($0) }
        .onAppear { model.refreshLoginItemStatus() }
    }

    // MARK: Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                )
        }
    }

    private func folderRow(_ title: String, systemImage: String, url: URL, hint: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundColor(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(abbreviated(url))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(url.path)
            }
            Spacer(minLength: 8)
            Button("Show in Finder") { NSWorkspace.shared.open(url) }
                .controlSize(.small)
                .accessibilityLabel("Show \(title.lowercased()) folder in Finder")
                .accessibilityHint(hint)
        }
        .padding(10)
    }

    // MARK: Helpers

    private var isUnavailable: Bool {
        if case .unavailable = model.loginItemStatus { return true }
        return false
    }

    private var loginCaption: String {
        switch model.loginItemStatus {
        case .enabled: return "Starts automatically when you log in."
        case .disabled: return "Start Command Manager yourself after logging in."
        case .requiresApproval: return "Waiting for approval in System Settings › Login Items."
        case .unavailable(let reason):
            let trimmed = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
            return "Unavailable: \(trimmed)."
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private func abbreviated(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func openLoginItems() {
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Accounts.prefPane"))
        }
    }
}

/// One appearance choice: a small window preview plus its name.
private struct AppearanceTile: View {
    let option: AppearancePreference
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                preview
                    .frame(height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                                          lineWidth: isSelected ? 2 : 1)
                    )
                Label(option.label, systemImage: option.symbol)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .accentColor : .primary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(option.label) appearance")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var preview: some View {
        switch option {
        case .light: MiniWindow(dark: false)
        case .dark: MiniWindow(dark: true)
        case .system:
            HStack(spacing: 0) {
                MiniWindow(dark: false)
                MiniWindow(dark: true)
            }
        }
    }
}

/// A tiny abstract window used in the appearance tiles.
private struct MiniWindow: View {
    let dark: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            (dark ? Color(white: 0.16) : Color(white: 0.96))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Circle().fill(Color.red.opacity(0.85)).frame(width: 4, height: 4)
                    Circle().fill(Color.yellow.opacity(0.85)).frame(width: 4, height: 4)
                    Circle().fill(Color.green.opacity(0.85)).frame(width: 4, height: 4)
                }
                RoundedRectangle(cornerRadius: 1.5).fill(line).frame(width: 34, height: 3)
                RoundedRectangle(cornerRadius: 1.5).fill(line).frame(width: 24, height: 3)
                RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor.opacity(0.8)).frame(width: 18, height: 3)
            }
            .padding(6)
        }
        .accessibilityHidden(true)
    }

    private var line: Color { dark ? Color.white.opacity(0.35) : Color.black.opacity(0.2) }
}
