import AppKit
import SwiftUI
import OpenAsyMacKit

/// Sidebar: search, saved queries, connections (this window's connection expanded: schemas, then tables, views,
/// functions), tools. ↑↓ selects; Return or a double click opens; right click or Control-click for the menu.
struct Sidebar: View {
    let ws: Workspace
    @Environment(\.oaMac) private var t
    @Environment(\.openWindow) private var openWindow
    @State private var selection: String?
    @State private var expanded: Set<String> = ["tables"]
    private var store: ConnectionStore { .shared }
    private var library: QueryLibrary { .shared }

    var filter: String { ws.sidebarFilter.trimmingCharacters(in: .whitespaces).lowercased() }
    func match(_ s: String) -> Bool { filter.isEmpty || s.lowercased().contains(filter) || (ws.tableInfo[s]?.columns.contains { $0.name.lowercased().contains(filter) } ?? false) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(t.muted).font(.system(size: 11))
                TextField(L.t("schema.filter"), text: Binding(get: { ws.sidebarFilter }, set: { ws.sidebarFilter = $0 })).textFieldStyle(.plain).font(OAMacFont.sans(12.5))
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(t.field, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(t.border2))
            .padding(10)

            List(selection: $selection) {
                let saved = library.saved.filter { $0.connectionID == nil || $0.connectionID == ws.conn?.id }.filter { match($0.name) }
                if !saved.isEmpty {
                    Section {
                        ForEach(saved) { q in row("bookmark", q.name).tag("saved:\(q.id)") }
                    } header: { OASectionHeader(L.t("saved.title")) }
                }
                Section {
                    if store.items.isEmpty {
                        Text(L.t("conns.emptyDesktop")).font(OAMacFont.sans(12)).foregroundStyle(t.text2).listRowBackground(Color.clear)
                    }
                    ForEach(store.items) { c in
                        if c.id == ws.conn?.id {
                            DisclosureGroup(isExpanded: binding("conn")) { tree } label: { connRow(c, current: true) }.tag("conn:\(c.id)")
                        } else {
                            connRow(c, current: false).tag("conn:\(c.id)")
                        }
                    }
                } header: { OASectionHeader(L.t("conns.title")) }
                if ws.isConnected {
                    Section {
                        if ws.dialect.userAdmin != nil { row("users", L.t("users.title")).tag("tool:users") }
                        row("diff", L.t("sync.title")).tag("tool:sync")
                        row("clock", L.t("history.title")).tag("tool:history")
                    } header: { OASectionHeader(L.t("tools.title")) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, OAMacMetrics.sidebarRow)
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first { menu(for: id) }
            } primaryAction: { ids in
                if let id = ids.first { open(id) }
            }
            .accessibilityLabel(L.t("sidebar.label"))

            HStack(spacing: 14) {
                Button { ws.editingConnection = SavedConnection() } label: { Image(systemName: "plus") }.help(L.t("conn.new")).accessibilityLabel(L.t("conn.new"))
                Button { Task { await ws.reloadObjects() } } label: { Image(systemName: "arrow.clockwise") }.help(L.t("schema.refresh")).accessibilityLabel(L.t("schema.refresh")).disabled(!ws.isConnected)
                Spacer()
                Button { ws.openSingleton(HistoryTab.self) { HistoryTab(ws: ws) } } label: { Image(systemName: "clock") }.help(L.t("history.title")).accessibilityLabel(L.t("history.title")).disabled(!ws.isConnected)
            }
            .buttonStyle(.plain).foregroundStyle(t.text2)
            .padding(.horizontal, 14).frame(height: 36)
            .overlay(alignment: .top) { Rectangle().fill(t.border).frame(height: 1) }
        }
        .background(t.chrome)
    }

    func binding(_ k: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(k) || k == "conn" && !expanded.contains("!conn") }, set: { v in
            if k == "conn" { if v { expanded.remove("!conn") } else { expanded.insert("!conn") } } else if v { expanded.insert(k) } else { expanded.remove(k) }
        })
    }

    func row(_ icon: String, _ title: String, mono: Bool = false, trailing: String? = nil) -> some View {
        HStack(spacing: 7) {
            OAMacIcon.image(icon).font(.system(size: 12)).foregroundStyle(t.text2).frame(width: 16)
            Text(title).font(mono ? OAMacFont.mono(12.5) : OAMacFont.sans(13)).foregroundStyle(t.text).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let trailing { Text(trailing).font(OAMacFont.mono(11)).foregroundStyle(t.muted) }
        }
        .accessibilityElement(children: .combine)
    }

    func connRow(_ c: SavedConnection, current: Bool) -> some View {
        HStack(spacing: 7) {
            OAMacIcon.image(c.kind.isFile ? "file" : "database").font(.system(size: 12)).foregroundStyle(t.text2).frame(width: 16)
            Text(c.displayName).font(OAMacFont.sans(13, current ? .medium : .regular)).foregroundStyle(t.text).lineLimit(1)
            Spacer(minLength: 4)
            if c.tag == .production { Text(L.t("conn.tag.production").uppercased(with: L.l10n.locale)).font(OAMacFont.sans(9.5, .semibold)).foregroundStyle(t.danger).padding(.horizontal, 4).background(t.dangerBg, in: RoundedRectangle(cornerRadius: 3)) }
            Text(c.kind.badge).font(OAMacFont.mono(10.5)).foregroundStyle(t.muted)
            Circle().fill(current && ws.isConnected ? t.ok : .clear).overlay(Circle().strokeBorder(current && ws.isConnected ? t.ok : t.muted, lineWidth: 1.3)).frame(width: 7, height: 7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(current && ws.isConnected ? L.t("conn.connected") : L.t("conn.disconnected"))
    }

    @ViewBuilder var tree: some View {
        if ws.isConnected {
            if ws.kind.isFile {
                objectsTree
            } else {
                ForEach(ws.schemas.filter { $0 == ws.schema || filter.isEmpty }, id: \.self) { s in
                    if s == ws.schema {
                        DisclosureGroup(isExpanded: binding("schema")) { objectsTree } label: { row("folder", s) }.tag("schema:\(s)")
                            .onAppear { expanded.insert("schema") }
                    } else {
                        row("folder", s).tag("schema:\(s)")
                    }
                }
            }
        }
    }

    @ViewBuilder var objectsTree: some View {
        let tables = ws.objects.tables.filter { match($0.name) }
        DisclosureGroup(isExpanded: binding("tables")) {
            ForEach(tables) { tb in
                row("table", tb.name, trailing: tb.rows.map { L.l10n.compact($0) }).tag("table:\(tb.name)")
                    .draggable(tb.name)
            }
        } label: { row("table", L.t("schema.tablesShort"), trailing: "\(tables.count)") }.tag("group:tables")
        let views = ws.objects.views.filter { match($0.name) }
        if !views.isEmpty {
            DisclosureGroup(isExpanded: binding("views")) {
                ForEach(views) { v in row("view", v.name).tag("view:\(v.name)") }
            } label: { row("view", L.t("schema.viewsShort"), trailing: "\(views.count)") }.tag("group:views")
        }
        let fns = ws.objects.functions.filter { match($0.name) }
        if !fns.isEmpty {
            DisclosureGroup(isExpanded: binding("functions")) {
                ForEach(fns) { f in row("function", f.name, mono: true).tag("fn:\(f.name)") }
            } label: { row("function", L.t("schema.functions"), trailing: "\(fns.count)") }.tag("group:fns")
        }
    }

    func open(_ id: String) {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let (kind, v) = (parts[0], parts[1])
        switch kind {
        case "table", "view": ws.openTable(v)
        case "saved":
            if let q = library.saved.first(where: { $0.id == v }) {
                let tab = ws.newQueryTab(sql: q.sql, title: q.name)
                tab.savedQueryID = q.id
            }
        case "conn": if v != ws.conn?.id { openWindow(value: v) } else if !ws.isConnected { Task { await ws.connect() } }
        case "schema": Task { await ws.selectSchema(v) }
        case "tool":
            switch v {
            case "users": ws.openSingleton(UsersTab.self) { let u = UsersTab(ws: ws); Task { await u.load() }; return u }
            case "sync": ws.openSingleton(SyncTab.self) { SyncTab(ws: ws) }
            default: ws.openSingleton(HistoryTab.self) { HistoryTab(ws: ws) }
            }
        case "fn": ws.newQueryTab(sql: "-- \(v)\n")
        default: break
        }
    }

    @ViewBuilder func menu(for id: String) -> some View {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            let v = parts[1]
            switch parts[0] {
            case "table", "view":
                Button(L.t("table.openData")) { ws.openTable(v, mode: .data) }
                if parts[0] == "table" { Button(L.t("table.openStructure")) { ws.openTable(v, mode: .structure) } }
                Button(L.t("table.ddl")) { ws.openTable(v, mode: .ddl) }
                Button(L.t("table.select")) {
                    ws.newQueryTab(sql: "SELECT * FROM \(ws.dialect.qualified(ws.kind.isFile ? nil : ws.schema, v)) LIMIT 100;").run(all: true)
                }
                Divider()
                Button(L.t("table.copyName")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(v, forType: .string) }
            case "conn":
                Button(L.t("conn.open")) { open(id) }
                Button(L.t("conn.edit")) { ws.editingConnection = store.connection(v) }
                Button(L.t("conn.duplicate")) {
                    if var c = store.connection(v) { c.id = DBID.make(); c.name += " 2"; store.upsert(c) }
                }
                if SchemaApp.isInstalled, let c = store.connection(v) {
                    Button(L.t("menu.openInSchema")) { SchemaApp.open(c, schema: SchemaApp.schema(for: c, in: ws)) }
                }
                Divider()
                Button(L.t("conn.delete"), role: .destructive) {
                    ws.confirm = .init(title: L.t("conn.delete"), text: L.t("conn.deleteQ", ["name": store.connection(v)?.displayName ?? ""]), action: L.t("conn.delete"), destructive: true) {
                        store.remove(v)
                    }
                }
            case "schema":
                if SchemaApp.isInstalled { Button(L.t("menu.openInSchema")) { SchemaApp.open(ws.conn, schema: v) } }
            case "saved":
                Button(L.t("saved.open")) { open(id) }
                Button(L.t("saved.delete"), role: .destructive) { library.deleteSaved(v) }
            default: EmptyView()
            }
        }
    }
}
