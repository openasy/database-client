import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OpenAsyMacKit

/// Settings window (⌘,): General, Editor, Connections, Backup
struct SettingsView: View {
    var body: some View {
        TabView {
            OAMacGeneralSettings(l10n: L.l10n) {
                Toggle(L.t("settings.confirmWrites"), isOn: Bindable(AppSettings.shared).confirmWrites)
                Toggle(L.t("settings.keepHistory"), isOn: Bindable(AppSettings.shared).keepHistory)
            }
            .tabItem { Label(L.t("kit_settings_general"), systemImage: "gearshape") }
            EditorSettings().tabItem { Label(L.t("settings.editor"), systemImage: "chevron.left.forwardslash.chevron.right") }
            ConnectionSettings().tabItem { Label(L.t("conns.title"), systemImage: "cylinder") }
            BackupSettings().tabItem { Label(L.t("kit_settings_backup"), systemImage: "archivebox") }
        }
        .frame(width: 620, height: 420)
    }
}

struct EditorSettings: View {
    @Bindable var s = AppSettings.shared
    var body: some View {
        Form {
            Stepper(L.t("settings.fontSize", ["n": String(format: "%.1f", s.editorFontSize)]), value: $s.editorFontSize, in: 9...24, step: 0.5)
            Toggle(L.t("settings.autocomplete"), isOn: $s.autocomplete)
            Picker(L.t("settings.pageSize"), selection: $s.pageSize) { ForEach([100, 250, 500, 1000, 2000], id: \.self) { Text(L.l10n.int($0)).tag($0) } }
            Picker(L.t("settings.maxRows"), selection: $s.maxRows) { ForEach([1000, 10_000, 50_000, 200_000], id: \.self) { Text(L.l10n.int($0)).tag($0) } }
            TextField(L.t("settings.nullText"), text: $s.nullText)
        }
        .formStyle(.grouped)
    }
}

struct ConnectionSettings: View {
    private var store: ConnectionStore { .shared }
    @State private var tick = 0
    var body: some View {
        Form {
            Section(L.t("settings.knownHosts")) {
                let hosts = store.knownHosts.all().sorted { $0.key < $1.key }
                if hosts.isEmpty { Text(L.t("settings.noKnownHosts")).foregroundStyle(.secondary) }
                ForEach(hosts, id: \.key) { k, v in
                    HStack {
                        VStack(alignment: .leading) { Text(k).font(OAMacFont.mono(12)); Text(v).font(OAMacFont.mono(10.5)).foregroundStyle(.secondary) }
                        Spacer()
                        Button(L.t("ssh.forget")) {
                            let p = k.split(separator: ":")
                            if p.count == 2, let port = Int(p[1]) { store.knownHosts.forget(host: String(p[0]), port: port); tick += 1 }
                        }
                    }
                }
            }
            Section { Text(L.t("settings.keychainNote")).font(OAMacFont.sans(11.5)).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .id(tick)
    }
}

struct BackupSettings: View {
    var body: some View {
        Form {
            Section {
                Text(L.t("backup.lead")).font(OAMacFont.sans(12)).foregroundStyle(.secondary)
                HStack {
                    Button(L.t("kit_backup")) { Backup.save(nil) }
                    Button(L.t("kit_restore")) { Backup.restore(nil) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Backup: connections (without passwords and bookmarks), saved queries, history, known hosts, settings
struct BackupData: Codable {
    var connections: [SavedConnection]
    var saved: [SavedQuery]
    var history: [HistoryEntry]
    var knownHosts: [String: String]
}

@MainActor
enum Backup {
    static let codec = OAMacBackup<BackupData>(product: AppInfo.id)

    static func save(_ ws: Workspace?) {
        let conns = ConnectionStore.shared.items.map { c -> SavedConnection in
            var x = c
            // File access is tied to this Mac; passwords are in the keychain already
            x.fileBookmark = nil; x.sshKeyBookmark = nil; x.caBookmark = nil; x.clientCertBookmark = nil; x.clientKeyBookmark = nil
            return x
        }
        let data = BackupData(connections: conns, saved: QueryLibrary.shared.saved, history: QueryLibrary.shared.history, knownHosts: ConnectionStore.shared.knownHosts.all())
        let p = NSSavePanel()
        p.nameFieldStringValue = codec.fileName(prefix: L.t("kit_backup_name").replacingOccurrences(of: "%s", with: AppInfo.name))
        p.allowedContentTypes = [UTType(exportedAs: "com.openasy.database-client-backup", conformingTo: .zip)]
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            try OAMacWrite.toUserFile(try codec.encode(data, appVersion: version), url)
            ws?.toasts.show(L.t("kit_backup_done"))
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func restore(_ ws: Workspace?) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(exportedAs: "com.openasy.database-client-backup", conformingTo: .zip), .zip]
        guard p.runModal() == .OK, let url = p.url else { return }
        let a = NSAlert()
        a.messageText = L.t("kit_restore_title")
        a.informativeText = L.t("kit_restore_text")
        a.addButton(withTitle: L.t("kit_restore_confirm"))
        a.addButton(withTitle: L.t("cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let (data, _) = try codec.decode(try Data(contentsOf: url))
            ConnectionStore.shared.replaceAll(data.connections)
            QueryLibrary.shared.replaceAll(history: data.history, saved: data.saved)
            for (k, v) in data.knownHosts {
                let parts = k.split(separator: ":")
                if parts.count == 2, let port = Int(parts[1]) { ConnectionStore.shared.knownHosts.trust(host: String(parts[0]), port: port, fingerprint: v) }
            }
            ws?.toasts.show(L.t("kit_restore_ok"))
        } catch {
            let e = NSAlert()
            e.messageText = L.t("kit_restore_failed").replacingOccurrences(of: "%s", with: error.localizedDescription)
            e.runModal()
        }
    }
}
