import AppKit
import SwiftUI
import OpenAsyMacKit

/// Main window: sidebar, tabbed content and inspector; toolbar and status bar
struct MainWindow: View {
    @State var ws: Workspace
    @Environment(\.oaMac) private var t
    @Environment(\.openWindow) private var openWindow

    init(connectionID: String?) { _ws = State(initialValue: Workspace(connectionID: connectionID)) }

    /// Tests and screenshots: DBCLIENT_OPEN=<connection name or id> opens that connection in the first window (once)
    nonisolated(unsafe) static var launched = false
    @MainActor static func launchConnection() -> String? {
        guard !launched, let v = ProcessInfo.processInfo.environment["DBCLIENT_OPEN"], !v.isEmpty else { return nil }
        launched = true
        return ConnectionStore.shared.items.first { $0.id == v || $0.name == v }?.id
    }

    var body: some View {
        OAMacWindow(showSidebar: ws.showSidebar, showInspector: ws.showInspector && ws.conn != nil) {
            header
        } sidebar: {
            Sidebar(ws: ws)
        } content: {
            VStack(spacing: 0) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                StatusBarView(ws: ws)
            }
        } inspector: {
            InspectorView(ws: ws)
        }
        .navigationTitle(ws.conn?.displayName ?? AppInfo.name)
        .oaToasts(ws.toasts)
        .focusedSceneValue(\.workspace, ws)
        .modifier(WorkspaceSheets(ws: ws))
        .onDisappear { Task { await ws.disconnect() } }
        .frame(minWidth: OAMacMetrics.minWindow.width, minHeight: OAMacMetrics.minWindow.height)
    }

    var subtitle: String {
        guard let c = ws.conn else { return L.t("welcome.noConn") }
        var parts = [c.kind.displayName + (ws.session.map { " " + $0.serverVersion } ?? "")]
        if !c.kind.isFile, !c.database.isEmpty { parts.append(c.database) }
        if !ws.schema.isEmpty, !c.kind.isFile { parts.append(ws.schema) }
        if c.tag == .production { parts.append(L.t("conn.tag.production").lowercased()) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder var content: some View {
        if ws.conn == nil {
            WelcomeView()
        } else {
            switch ws.state {
            case .connected:
                VStack(spacing: 0) {
                    OATabBar(tabs: ws.tabs.map { OATab(id: $0.id, title: $0.title, icon: $0.icon, dirty: $0.isDirty) },
                             selection: $ws.selectedTab, addLabel: L.t("query.newTab"), closeLabel: L.t("close"),
                             onClose: { ws.close($0) }, onAdd: { ws.newQueryTab() })
                    if let tab = ws.selected {
                        TabContent(ws: ws, tab: tab).id(tab.id)
                    } else {
                        OAEmptyState(icon: "code", title: L.t("tabs.emptyTitle"), text: L.t("tabs.emptyText")) {
                            Button(L.t("query.newTab")) { ws.newQueryTab() }.buttonStyle(.oaPrimary)
                        }
                    }
                }
            case .connecting:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(L.t("conn.connecting", ["name": ws.conn?.displayName ?? ""])).font(OAMacFont.sans(13)).foregroundStyle(t.text2)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .idle:
                OAEmptyState(icon: "database", title: ws.conn?.displayName ?? "", text: L.t("conn.notConnected")) {
                    Button(L.t("conn.connect")) { Task { await ws.connect() } }.buttonStyle(.oaPrimary).keyboardShortcut(.defaultAction)
                    Button(L.t("conn.edit")) { ws.editingConnection = ws.conn }.buttonStyle(.oaSecondary)
                }
            case .failed(let msg):
                ConnFailedView(ws: ws, message: msg)
            }
        }
    }

    /// Toolbar: sidebar, title, state; on the right the run group, transaction, new tab, share, inspector
    @ViewBuilder var header: some View {
        HeaderIcon("sidebar.left", L.t("view.sidebar") + " (⌃⌘S)") { ws.showSidebar.toggle() }
        VStack(alignment: .leading, spacing: 1) {
            Text(ws.conn?.displayName ?? AppInfo.name).font(OAMacFont.sans(13, .semibold)).foregroundStyle(t.text).lineLimit(1)
            Text(subtitle).font(OAMacFont.sans(11.5)).foregroundStyle(t.text2).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        if ws.conn != nil { pill }
        Spacer(minLength: 8)
        if let q = ws.selected as? QueryTab {
            HStack(spacing: 2) {
                Button { q.run(all: false) } label: { Label(L.t("query.run"), systemImage: "play.fill").labelStyle(.titleAndIcon) }
                    .buttonStyle(.oa(.primary, .small)).help(L.t("query.run") + " (⌘↩)").disabled(q.running || !ws.isConnected)
                Button(L.t("query.plan")) { q.explain() }.buttonStyle(.oa(.plain, .small)).help(L.t("query.plan") + " (⌥⌘E)").disabled(q.running || !ws.isConnected)
                Button(L.t("query.stop")) { q.stop() }.buttonStyle(.oa(.plain, .small)).help(L.t("query.stop") + " (⌘.)").disabled(!q.running)
            }
            .padding(3).background(t.panel2, in: Capsule()).overlay(Capsule().strokeBorder(t.border))
        }
        if ws.isConnected {
            Menu {
                Button(L.t("tx.begin")) { Task { await ws.beginTransaction() } }.disabled(ws.inTransaction)
                Button(L.t("tx.commit")) { Task { await ws.commit() } }.disabled(!ws.inTransaction)
                Button(L.t("tx.rollback")) { Task { await ws.rollback() } }.disabled(!ws.inTransaction)
            } label: {
                Label(ws.inTransaction ? L.t("tx.open", ["n": ws.pendingTxStatements]) : L.t("tx.autocommit"), systemImage: "square.stack.3d.up")
                    .font(OAMacFont.sans(12, .medium)).foregroundStyle(ws.inTransaction ? t.warn : t.text)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .padding(.horizontal, 12).frame(height: 30).background(t.panel2, in: Capsule()).overlay(Capsule().strokeBorder(ws.inTransaction ? t.warn : t.border))
            .help(L.t("tx.help"))
        }
        HStack(spacing: 2) {
            HeaderIcon("plus", L.t("query.newTab") + " (⌘T)") { ws.newQueryTab() }.disabled(!ws.isConnected)
            HeaderIcon("square.and.arrow.up", L.t("share")) { ShareButton(ws: ws).share(ws) }.disabled(ws.selected == nil)
            HeaderIcon("sidebar.right", L.t("view.inspector") + " (⌥⌘0)", on: ws.showInspector) { ws.showInspector.toggle() }.disabled(ws.conn == nil)
        }
        .padding(3).background(t.panel2, in: Capsule()).overlay(Capsule().strokeBorder(t.border))
    }

    var pill: some View {
        let ssh = ws.conn?.sshEnabled == true ? " · SSH" : ""
        return HStack(spacing: 6) {
            switch ws.state {
            case .connected: OAStatusPill(.connected, L.t("conn.connected") + ssh)
            case .connecting: OAStatusPill(.connecting, L.t("conn.connectingShort"))
            case .idle: OAStatusPill(.disconnected, L.t("conn.disconnected"))
            case .failed: OAStatusPill(.failed, L.t("conn.failedShort"))
            }
            if ws.isProduction { OAStatusPill(.production, L.t("conn.tag.production").uppercased(with: L.l10n.locale)) }
        }
    }
}

/// Toolbar icon button (28 pt)
struct HeaderIcon: View {
    let symbol: String
    let label: String
    var on = false
    let action: () -> Void
    @Environment(\.oaMac) private var t
    init(_ symbol: String, _ label: String, on: Bool = false, action: @escaping () -> Void) { self.symbol = symbol; self.label = label; self.on = on; self.action = action }
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 28, height: 26)
                .foregroundStyle(on ? t.accentText : t.text2)
                .background(on ? t.pressed : .clear, in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

struct ImportTarget: Identifiable { let table: String; var id: String { table } }

struct TabContent: View {
    let ws: Workspace
    let tab: WorkTab
    var body: some View {
        switch tab {
        case let q as QueryTab: QueryView(ws: ws, tab: q)
        case let t as TableTab: TableTabView(ws: ws, tab: t)
        case let u as UsersTab: UsersView(ws: ws, tab: u)
        case let s as SyncTab: SyncView(ws: ws, tab: s)
        case let h as HistoryTab: HistoryView(ws: ws, tab: h)
        default: EmptyView()
        }
    }
}

struct StatusBarView: View {
    let ws: Workspace
    @Environment(\.oaMac) private var t
    var body: some View {
        OAStatusBar {
            HStack(spacing: 6) {
                Circle().fill(ws.isConnected ? t.ok : .clear).overlay(Circle().strokeBorder(ws.isConnected ? t.ok : t.muted, lineWidth: 1.5)).frame(width: 8, height: 8)
                Text(ws.isConnected ? L.t("conn.connected") : L.t("conn.disconnected"))
            }
            if let c = ws.conn {
                Text(c.kind.isFile ? (c.filePath ?? "") : "\(c.user)@\(c.host)" + (c.sshEnabled ? " · SSH \(c.sshHost)" : "")).truncationMode(.middle)
            }
            if ws.isConnected { Text(ws.inTransaction ? L.t("tx.open", ["n": ws.pendingTxStatements]) : L.t("tx.autocommit")) }
        } trailing: {
            switch ws.selected {
            case let q as QueryTab:
                if let r = q.current { Text(L.t("query.rows", ["n": r.result.rows.count, "ms": L.msNumber(r.result.ms)])) }
                Text(L.t("editor.cursor", ["line": q.cursor.line, "col": q.cursor.col])).font(OAMacFont.mono(11))
            case let tt as TableTab:
                Text(L.t("data.loaded", ["n": tt.rows.count, "total": tt.total.map { L.l10n.int64($0) } ?? "?"]) + " · " + L.l10n.ms(tt.lastMs))
                Text("\(tt.schema).\(tt.table)").font(OAMacFont.mono(11))
            default: EmptyView()
            }
        }
    }
}

struct ConnFailedView: View {
    let ws: Workspace
    let message: String
    @Environment(\.oaMac) private var t
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L.t("conn.failedTitle", ["name": ws.conn?.displayName ?? ""]), systemImage: "xmark.octagon").font(OAMacFont.sans(15, .semibold)).foregroundStyle(t.danger)
            OANotice(.error, message)
            Text(L.t("conn.failedHelp")).font(OAMacFont.sans(12.5)).foregroundStyle(t.text2)
            HStack {
                Button(L.t("conn.retry")) { Task { await ws.connect() } }.buttonStyle(.oaPrimary).keyboardShortcut(.defaultAction)
                Button(L.t("conn.edit")) { ws.editingConnection = ws.conn }.buttonStyle(.oaSecondary)
            }
        }
        .padding(28).frame(maxWidth: 620).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Share: the selected tab's result (CSV) or the query text (.sql); the operating system's share menu
struct ShareButton: View {
    let ws: Workspace
    var body: some View {
        Button {
            share(ws)
        } label: { Label(L.t("share"), systemImage: "square.and.arrow.up") }
        .help(L.t("share"))
        .disabled(ws.selected == nil)
    }

    @MainActor static func items(_ ws: Workspace) -> (Data, String)? {
        switch ws.selected {
        case let q as QueryTab:
            if let r = q.current { return (Data(Exporter.render(r, rows: nil, format: .csv, table: nil, dialect: ws.dialect).utf8), L.t("query.exportName") + ".csv") }
            return (Data(q.sql.utf8), q.title + ".sql")
        case let tt as TableTab:
            return (Data(Exporter.render(tt, rows: nil, format: .csv, table: tt.table, dialect: ws.dialect).utf8), tt.table + ".csv")
        default: return nil
        }
    }

    @MainActor func share(_ ws: Workspace) {
        guard let (d, name) = Self.items(ws) else { return }
        OAMacShare.share(data: d, fileName: name, from: NSApp.keyWindow?.contentView)
    }
}

struct WorkspaceKey: FocusedValueKey { typealias Value = Workspace }
extension FocusedValues {
    var workspace: Workspace? {
        get { self[WorkspaceKey.self] }
        set { self[WorkspaceKey.self] = newValue }
    }
}

/// The window's sheets, alerts and launch work (kept apart from the main body for the type checker)
struct WorkspaceSheets: ViewModifier {
    @Bindable var ws: Workspace
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .modifier(Sheets1(ws: ws))
            .modifier(Sheets2(ws: ws))
    }
}

struct Sheets1: ViewModifier {
    @Bindable var ws: Workspace
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content
            .sheet(item: $ws.editingConnection) { c in
                ConnectionSheet(initial: c) { saved, connect in
                    ws.editingConnection = nil
                    if let saved, connect {
                        if saved.id == ws.conn?.id { ws.conn = saved; Task { await ws.disconnect(); await ws.connect() } } else { openWindow(value: saved.id) }
                    }
                }
            }
            .sheet(item: $ws.prompt) { p in PromptSheet(ws: ws, prompt: p) }
            .sheet(isPresented: $ws.showSaveQuery) {
                if let q = ws.selected as? QueryTab { SaveQuerySheet(ws: ws, tab: q) { ws.showSaveQuery = false } }
            }
    }
}

struct Sheets2: ViewModifier {
    @Bindable var ws: Workspace
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { ws.importTable.map { ImportTarget(table: $0) } }, set: { ws.importTable = $0?.table })) { it in
                ImportSheet(ws: ws, table: it.table) { ws.importTable = nil }
            }
            .onAppear {
                LinkRouter.shared.openWindow = openWindow
                if ws.conn != nil { LinkRouter.shared.register(ws) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openConnection)) { n in
                if let id = n.object as? String, ws.conn == nil { openWindow(value: id) }
            }
            .alert(ws.confirm?.title ?? "", isPresented: Binding(get: { ws.confirm != nil }, set: { if !$0 { ws.confirm = nil } }), presenting: ws.confirm) { c in
                Button(c.action, role: c.destructive ? .destructive : nil) { c.run(); ws.confirm = nil }
                Button(L.t("cancel"), role: .cancel) { ws.confirm = nil }
            } message: { c in Text(c.text) }
            .task {
                if ws.conn != nil, ws.state == .idle { await ws.connect() }
                #if DEBUG
                if ws.isConnected { await Demo.run(ws) } else { Demo.runIdle(ws) }
                Demo.shoot(after: 3.5)
                #endif
            }
    }
}
