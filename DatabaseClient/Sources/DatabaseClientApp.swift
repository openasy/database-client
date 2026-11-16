import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OpenAsyMacKit

/// The app's names and addresses, in one place.
enum AppInfo {
    static let name = "OpenAsy Database Client"
    /// Short id: backup file names, `updatedBy` in the shared connection list
    static let id = "database-client"
    /// Folder under Application Support (in the sandbox container)
    static let folder = "OpenAsy Database Client"
    static let license = "AGPL-3.0-only"
    static let repository = URL(string: "https://github.com/openasy/database-client")!
    static let privacy = URL(string: "https://github.com/openasy/database-client#privacy")!
}

@main
struct DatabaseClientApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    let theme = OAMacTheme.openasy

    init() {
        OAMacFont.register()
        OAMacTheme.current = OAMacTheme.openasy
        DBEngines.applicationName = AppInfo.name
        // Screenshots and tests: -theme dark|light
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-theme"), i + 1 < args.count { UserDefaults.standard.set(args[i + 1], forKey: "openasy.theme") }
    }

    var body: some Scene {
        WindowGroup(for: String.self) { $id in
            // A window without a connection is the welcome screen; for tests DBCLIENT_OPEN opens a connection in the
            // first window
            MainWindow(connectionID: id.flatMap { $0.isEmpty ? nil : $0 } ?? MainWindow.launchConnection())
                .oaMacTheme(theme)
                .environment(\.locale, L.l10n.locale)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: OAMacMetrics.defaultWindow.width, height: OAMacMetrics.defaultWindow.height)
        .commands { DatabaseClientCommands() }
        // SwiftUI must not open a window by itself for openasy-database-client:// links: AppDelegate and LinkRouter
        // open it
        .handlesExternalEvents(matching: [])

        Settings {
            SettingsView().oaMacTheme(theme).environment(\.locale, L.l10n.locale)
        }

        Window(L.t("about.title"), id: "about") {
            OAMacAboutView(info: .fromBundle(repository: AppInfo.repository, license: AppInfo.license, note: L.t("about.text"), licenses: Licenses.all), l10n: L.l10n)
                .oaMacTheme(theme)
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: [])
        .windowStyle(.hiddenTitleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Unit tests open the app as their host: no window, no focus
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { NSApp.setActivationPolicy(.prohibited) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        MainActor.assumeIsolated { OAMacAppearance.apply(OAMacAppearance.saved) }
        NSWindow.allowsAutomaticWindowTabbing = true
        // If window restoration leaves no window (or the app opened in the background), a window is opened
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A file opened from Finder (.sqlite, .db) is added as a connection and its window opens.
    /// `openasy-database-client://` links ("Open in Database Client" from OpenAsy Schema): LinkRouter.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for u in urls where !u.isFileURL { LinkRouter.shared.handle(u) }
            for u in urls where u.isFileURL && ["sqlite", "sqlite3", "db", "db3"].contains(u.pathExtension.lowercased()) {
                let c = addSQLite(u)
                NotificationCenter.default.post(name: .openConnection, object: c.id)
            }
        }
    }
}

extension Notification.Name { static let openConnection = Notification.Name("openasy.database-client.openConnection") }

/// The menu bar. Shortcuts do not clash with their built-in meaning in macOS.
struct DatabaseClientCommands: Commands {
    @FocusedValue(\.workspace) var ws
    @Environment(\.openWindow) var openWindow

    var query: QueryTab? { ws?.selected as? QueryTab }
    var table: TableTab? { ws?.selected as? TableTab }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L.l10n.t("kit_about", AppInfo.name)) { openWindow(id: "about") }
        }
        CommandGroup(replacing: .newItem) {
            Button(L.t("conn.new") + "…") { if let ws { ws.editingConnection = SavedConnection() } else { openWindow(value: "") } }.keyboardShortcut("n")
            Button(L.t("query.newTab")) { ws?.newQueryTab() }.keyboardShortcut("t").disabled(ws?.isConnected != true)
            Button(L.t("menu.newWindow")) { openWindow(value: "") }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button(L.t("sqlite.open")) { openSQLite { openWindow(value: $0) } }.keyboardShortcut("o")
            Divider()
            Button(L.t("menu.closeTab")) { if let ws, let id = ws.selectedTab { ws.close(id) } else { NSApp.keyWindow?.performClose(nil) } }.keyboardShortcut("w")
        }
        CommandGroup(replacing: .saveItem) {
            Button(L.t("menu.save")) { save() }.keyboardShortcut("s").disabled(ws == nil)
            Button(L.t("menu.saveSQL")) { saveSQLFile() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(query == nil)
            Button(L.t("menu.openSql")) { openSQLFile() }.disabled(ws?.isConnected != true)
            Divider()
            Button(L.t("import.menu")) { if let table { ws?.importTable = table.table } }.keyboardShortcut("i", modifiers: [.command, .shift]).disabled(table == nil || table?.editable != true)
            Menu(L.t("export.title")) {
                ForEach(Exporter.Format.allCases) { f in Button(L.t("export.\(f.rawValue)")) { export(f) } }
            }.disabled(exportSource == nil)
            Button(L.t("share") + "…") { if let ws { ShareButton(ws: ws).share(ws) } }.disabled(ws?.selected == nil)
            Divider()
            Button(L.t("kit_backup")) { Backup.save(ws) }
            Button(L.t("kit_restore")) { Backup.restore(ws) }
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button(L.t("menu.comment")) { query?.editor.toggleComment(prefix: "-- ") }.keyboardShortcut("/").disabled(query == nil)
            Button(L.t("menu.format")) { if let q = query { q.editor.replaceAll(SQLFormat.format(q.sql)) } }.keyboardShortcut("i", modifiers: .control).disabled(query == nil)
            Divider()
            Button(L.t("data.addRow")) { table?.addRow() }.keyboardShortcut("n", modifiers: [.command, .option]).disabled(table?.editable != true)
            Button(L.t("data.deleteRows")) { if let t = table { t.deleteRows(t.selectedRows) } }.keyboardShortcut(.delete, modifiers: .command).disabled(table?.editable != true)
            Button(L.t("data.setNull")) { table?.setNullSelected() }.keyboardShortcut("0", modifiers: [.command, .option, .shift]).disabled(table?.editable != true)
        }
        CommandGroup(after: .sidebar) {
            Button(L.t("view.sidebar")) { ws?.showSidebar.toggle() }.keyboardShortcut("s", modifiers: [.command, .control])
            Button(L.t("view.inspector")) { ws?.showInspector.toggle() }.keyboardShortcut("0", modifiers: [.command, .option])
            Divider()
            Button(L.t("table.data")) { table?.mode = .data }.keyboardShortcut("1", modifiers: [.command, .control]).disabled(table == nil)
            Button(L.t("table.structure")) { table?.mode = .structure }.keyboardShortcut("2", modifiers: [.command, .control]).disabled(table == nil || table?.isView == true)
            Button(L.t("table.createSQL")) { table?.mode = .ddl }.keyboardShortcut("3", modifiers: [.command, .control]).disabled(table == nil)
            Divider()
            Button(L.t("view.biggerText")) { AppSettings.shared.editorFontSize = min(24, AppSettings.shared.editorFontSize + 1) }.keyboardShortcut("+")
            Button(L.t("view.smallerText")) { AppSettings.shared.editorFontSize = max(9, AppSettings.shared.editorFontSize - 1) }.keyboardShortcut("-")
            Button(L.t("view.actualSize")) { AppSettings.shared.editorFontSize = 12.5 }.keyboardShortcut("0")
        }
        CommandMenu(L.t("menu.query")) {
            Button(L.t("query.run")) { query?.run(all: false) }.keyboardShortcut(.return).disabled(query == nil || ws?.isConnected != true)
            Button(L.t("query.runAll")) { query?.run(all: true) }.keyboardShortcut(.return, modifiers: [.command, .shift]).disabled(query == nil || ws?.isConnected != true)
            Button(L.t("query.plan")) { query?.explain() }.keyboardShortcut("e", modifiers: [.command, .option]).disabled(query == nil || ws?.isConnected != true)
            Button(L.t("query.stop")) { query?.stop() }.keyboardShortcut(".").disabled(query?.running != true)
            Divider()
            Button(L.t("tx.begin")) { Task { await ws?.beginTransaction() } }.keyboardShortcut("t", modifiers: [.command, .option]).disabled(ws?.isConnected != true || ws?.inTransaction == true)
            Button(L.t("tx.commit")) { Task { await ws?.commit() } }.keyboardShortcut(.return, modifiers: [.command, .option]).disabled(ws?.inTransaction != true)
            Button(L.t("tx.rollback")) { Task { await ws?.rollback() } }.keyboardShortcut(.delete, modifiers: [.command, .option]).disabled(ws?.inTransaction != true)
            Divider()
            Button(L.t("saved.save")) { ws?.showSaveQuery = true }.keyboardShortcut("d").disabled(query == nil)
            Button(L.t("saved.title")) { if let ws { ws.openSingleton(HistoryTab.self) { HistoryTab(ws: ws) }; (ws.selected as? HistoryTab)?.section = 1 } }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(ws?.isConnected != true)
            Button(L.t("history.title")) { if let ws { ws.openSingleton(HistoryTab.self) { HistoryTab(ws: ws) }; (ws.selected as? HistoryTab)?.section = 0 } }.keyboardShortcut("y").disabled(ws?.isConnected != true)
            Divider()
            Button(L.t("menu.prevResult")) { if let q = query, q.selectedResult > 0 { q.selectedResult -= 1 } }.keyboardShortcut("[", modifiers: [.command, .option]).disabled(query == nil)
            Button(L.t("menu.nextResult")) { if let q = query, q.selectedResult < q.results.count - 1 { q.selectedResult += 1 } }.keyboardShortcut("]", modifiers: [.command, .option]).disabled(query == nil)
        }
        CommandMenu(L.t("menu.connection")) {
            Button(L.t("conn.connect")) { Task { await ws?.connect() } }.keyboardShortcut("k").disabled(ws?.conn == nil || ws?.isConnected == true)
            Button(L.t("conn.close")) { Task { await ws?.disconnect() } }.keyboardShortcut("k", modifiers: [.command, .shift]).disabled(ws?.isConnected != true)
            Button(L.t("conn.edit") + "…") { ws?.editingConnection = ws?.conn }.keyboardShortcut("e").disabled(ws?.conn == nil)
            if SchemaApp.isInstalled {
                Button(L.t("menu.openInSchema")) { if let c = ws?.conn { SchemaApp.open(c, schema: SchemaApp.schema(for: c, in: ws)) } }.disabled(ws?.conn == nil)
            }
            Divider()
            Button(L.t("schema.refresh")) { Task { await ws?.reloadObjects() } }.keyboardShortcut("r").disabled(ws?.isConnected != true)
            Divider()
            Button(L.t("users.title")) { if let ws { ws.openSingleton(UsersTab.self) { let u = UsersTab(ws: ws); Task { await u.load() }; return u } } }
                .disabled(ws?.isConnected != true || ws?.dialect.userAdmin == nil)
            Button(L.t("menu.compare")) { if let ws { ws.openSingleton(SyncTab.self) { SyncTab(ws: ws) } } }.disabled(ws?.isConnected != true)
        }
        CommandGroup(after: .windowArrangement) {
            Button(L.t("menu.nextTab")) { ws?.cycleTab(1) }.keyboardShortcut(.tab, modifiers: .control)
            Button(L.t("menu.prevTab")) { ws?.cycleTab(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
        }
        CommandGroup(replacing: .help) {
            Button(L.t("kit_licenses")) { openWindow(id: "about") }
            Button(L.t("kit_privacy")) { NSWorkspace.shared.open(AppInfo.privacy) }
            Divider()
            Button(L.t("kit_source_code")) { NSWorkspace.shared.open(AppInfo.repository) }
            Button(L.t("kit_report_issue")) { NSWorkspace.shared.open(OAMacLinks.issues(AppInfo.repository)) }
            Button(L.t("kit_website")) { NSWorkspace.shared.open(OAMacLinks.website) }
        }
    }

    var exportSource: OADataGridSource? {
        if let q = query { return q.current }
        return table
    }

    func export(_ f: Exporter.Format) {
        guard let src = exportSource else { return }
        Exporter.save(src, rows: nil, format: f, name: table?.table ?? L.t("query.exportName"), table: table?.table, dialect: ws?.dialect, ws: ws)
    }

    /// ⌘S: commit in table data, preview in structure, save the query in a query tab
    func save() {
        if let t = table {
            if t.mode == .structure, t.hasStructureChanges { t.showStructurePreview = true } else if t.hasDataChanges { t.commit() }
        } else if query != nil { ws?.showSaveQuery = true }
    }

    func saveSQLFile() {
        guard let q = query else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = q.title + ".sql"
        p.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        guard p.runModal() == .OK, let url = p.url else { return }
        try? OAMacWrite.toUserFile(Data(q.sql.utf8), url)
        q.savedSQL = q.sql
    }

    func openSQLFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText, .plainText]
        guard p.runModal() == .OK, let url = p.url, let s = try? String(contentsOf: url, encoding: .utf8) else { return }
        ws?.newQueryTab(sql: s, title: url.deletingPathExtension().lastPathComponent)
    }
}

/// A simple SQL formatter (⌃I): a line break before the main keywords
enum SQLFormat {
    static func format(_ sql: String) -> String {
        var out = ""
        for (tok, r) in SQLLexer.tokenize(sql) {
            let s = (sql as NSString).substring(with: r)
            let up = s.uppercased()
            if tok == .keyword, ["SELECT", "FROM", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "JOIN", "LEFT", "RIGHT", "INNER", "UNION", "VALUES", "SET", "RETURNING"].contains(up), !out.isEmpty, !out.hasSuffix("\n") {
                if !(up == "JOIN" && (out.hasSuffix("LEFT ") || out.hasSuffix("RIGHT ") || out.hasSuffix("INNER ") || out.hasSuffix("FULL ") || out.hasSuffix("CROSS "))) { out = out.trimmingCharacters(in: .whitespaces) + "\n" }
            }
            if tok == .op, s == "," || s == ";" || s == ")" || s == "." { out = out.trimmingCharacters(in: CharacterSet(charactersIn: " ")) }
            out += tok == .keyword ? up : s
            if tok == .op, s == "(" || s == "." { continue }
            out += s == ";" ? "\n\n" : " "
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

/// Open-source licences (About, Licences)
enum Licenses {
    static let all: [OAMacLicense] = [
        .init(name: "IBM Plex Sans / Mono", license: "OFL-1.1", url: "https://github.com/IBM/plex"),
        .init(name: "CodeEditTextView", license: "MIT", url: "https://github.com/CodeEditApp/CodeEditTextView"),
        .init(name: "TextStory", license: "BSD-3-Clause", url: "https://github.com/ChimeHQ/TextStory"),
        .init(name: "PostgresNIO", license: "MIT", url: "https://github.com/vapor/postgres-nio"),
        .init(name: "MySQLNIO", license: "MIT", url: "https://github.com/vapor/mysql-nio"),
        .init(name: "Citadel", license: "MIT", url: "https://github.com/orlandos-nl/Citadel"),
        .init(name: "SwiftNIO, SwiftNIO SSL, SwiftNIO SSH", license: "Apache-2.0", url: "https://github.com/apple/swift-nio"),
        .init(name: "swift-crypto, swift-collections, swift-log, swift-atomics, swift-algorithms, swift-metrics, swift-service-lifecycle, swift-nio-transport-services", license: "Apache-2.0", url: "https://github.com/apple"),
        .init(name: "BoringSSL", license: "ISC / OpenSSL", url: "https://boringssl.googlesource.com/boringssl"),
        .init(name: "BigInt", license: "MIT", url: "https://github.com/attaswift/BigInt"),
        .init(name: "ColorizeSwift", license: "MIT", url: "https://github.com/mtynior/ColorizeSwift"),
        .init(name: "SQLite", license: "Public domain", url: "https://sqlite.org"),
    ]
}
