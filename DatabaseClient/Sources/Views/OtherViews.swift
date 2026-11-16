import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OpenAsyMacKit

/// Welcome (a window without a connection)
struct WelcomeView: View {
    @Environment(\.oaMac) private var t
    @Environment(\.openWindow) private var openWindow
    @State private var editing: SavedConnection?

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 76, height: 76).accessibilityHidden(true)
            Text(L.t("welcome.title")).font(OAMacFont.sans(20, .semibold)).foregroundStyle(t.text)
            Text(L.t("welcome.leadMac")).font(OAMacFont.sans(13)).foregroundStyle(t.text2).multilineTextAlignment(.center).frame(maxWidth: 520)
            HStack(spacing: 8) {
                Button(L.t("conn.new") + "…  ⌘N") { editing = SavedConnection() }.buttonStyle(.oa(.primary, .large))
                Button(L.t("sqlite.open") + "  ⌘O") { openSQLite { openWindow(value: $0) } }.buttonStyle(.oa(.secondary, .large))
                Button(L.t("sample.open")) { openSample { openWindow(value: $0) } }.buttonStyle(.oa(.secondary, .large))
            }
            HStack(alignment: .top, spacing: 12) {
                card(L.t("welcome.c1"), L.t("welcome.f1"))
                card(L.t("welcome.c2"), L.t("welcome.f2mac"))
                card(L.t("welcome.c3"), L.t("welcome.f3"))
            }
            .padding(.top, 14).frame(maxWidth: 700)
            Text(L.t("welcome.dropMac")).font(OAMacFont.sans(11.5)).foregroundStyle(t.muted).padding(.top, 6)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $editing) { c in
            ConnectionSheet(initial: c) { saved, connect in
                editing = nil
                if let saved, connect { openWindow(value: saved.id) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            openWindow(value: addSQLite(u).id)
            return true
        }
    }

    func card(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(OAMacFont.sans(12, .semibold)).foregroundStyle(t.text2)
            Text(text).font(OAMacFont.sans(12.5)).foregroundStyle(t.text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(t.panel2, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(t.border))
    }
}

@MainActor
func addSQLite(_ url: URL) -> SavedConnection {
    if let c = ConnectionStore.shared.items.first(where: { $0.filePath == url.path }) { return c }
    var c = SavedConnection()
    c.kind = .sqlite
    c.port = 0
    c.fileBookmark = OAMacBookmark.make(url)
    c.filePath = url.path
    c.name = url.lastPathComponent
    ConnectionStore.shared.upsert(c)
    return c
}

@MainActor
func openSQLite(_ open: (String) -> Void) {
    let p = NSOpenPanel()
    p.allowedContentTypes = ["sqlite", "sqlite3", "db", "db3"].compactMap { UTType(filenameExtension: $0) } + [.data]
    guard p.runModal() == .OK, let url = p.url else { return }
    open(addSQLite(url).id)
}

/// Sample database: a small shop (SQLite) in the app's own folder, with names in the UI language
@MainActor
func openSample(_ open: @escaping (String) -> Void) {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(AppInfo.folder, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(L.t("sample.file") + ".sqlite")
    if !FileManager.default.fileExists(atPath: url.path) {
        Task {
            if let s = try? await DBEngines.connect(DBConnectConfig(kind: .sqlite, file: url)) {
                for sql in Sample.sql(categories: L.t("sample.categories"), products: L.t("sample.products")) { _ = try? await s.execute(sql) }
                await s.close()
            }
            open(addSQLite(url).id)
        }
    } else { open(addSQLite(url).id) }
}

enum Sample {
    static func sql(categories: String, products: String) -> [String] {
        let cats = categories.split(separator: "|").map(String.init)
        let prods = products.split(separator: "|").map(String.init)
        var out = [
            "CREATE TABLE categories (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)",
            "CREATE TABLE products (id INTEGER PRIMARY KEY AUTOINCREMENT, category_id INTEGER REFERENCES categories(id), name TEXT NOT NULL, price NUMERIC NOT NULL DEFAULT 0, stock INTEGER NOT NULL DEFAULT 0)",
            "CREATE TABLE customers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, email TEXT, city TEXT, created_at TEXT DEFAULT CURRENT_TIMESTAMP)",
            "CREATE TABLE orders (id INTEGER PRIMARY KEY AUTOINCREMENT, customer_id INTEGER NOT NULL REFERENCES customers(id), total NUMERIC NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'new', meta TEXT, created_at TEXT DEFAULT CURRENT_TIMESTAMP)",
            "CREATE INDEX orders_status_idx ON orders (status)",
            "CREATE TABLE order_items (id INTEGER PRIMARY KEY AUTOINCREMENT, order_id INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE, product_id INTEGER NOT NULL REFERENCES products(id), qty INTEGER NOT NULL DEFAULT 1, unit_price NUMERIC NOT NULL)",
            "CREATE VIEW monthly_revenue AS SELECT substr(created_at, 1, 7) AS month, COUNT(*) AS orders, SUM(total) AS revenue FROM orders GROUP BY 1",
        ]
        for c in cats { out.append("INSERT INTO categories (name) VALUES ('\(c.replacingOccurrences(of: "'", with: "''"))')") }
        for (i, p) in prods.enumerated() {
            out.append("INSERT INTO products (category_id, name, price, stock) VALUES (\(i % max(1, cats.count) + 1), '\(p.replacingOccurrences(of: "'", with: "''"))', \(Double(19 + i * 37 % 400) + 0.9), \(5 + i * 13 % 90))")
        }
        let names = ["Ayşe Demir", "Mehmet Kaya", "Elif Şahin", "Can Yıldız", "Zeynep Arslan", "Burak Çelik", "Deniz Aydın", "Selin Koç", "Emre Öztürk", "Ece Kurt"]
        let cities = ["İstanbul", "Ankara", "İzmir", "Bursa", "Antalya"]
        for (i, n) in names.enumerated() {
            out.append("INSERT INTO customers (name, email, city, created_at) VALUES ('\(n)', 'user\(i + 1)@example.com', '\(cities[i % cities.count])', datetime('2026-10-01', '+\(i) days'))")
        }
        let statuses = ["shipped", "paid", "pending", "delivered"]
        for i in 0..<60 {
            let meta = i % 3 == 0 ? "NULL" : "'{\"channel\":\"\(i % 2 == 0 ? "web" : "mobile")\",\"coupon\":\(i % 4 == 0 ? "\"NOV10\"" : "null")}'"
            out.append("INSERT INTO orders (customer_id, total, status, meta, created_at) VALUES (\(i % names.count + 1), \(Double(59 + i * 71 % 2300) + 0.5), '\(statuses[i % statuses.count])', \(meta), datetime('2026-10-01', '+\(i / 2) days', '+\(i * 37 % 600) minutes'))")
            out.append("INSERT INTO order_items (order_id, product_id, qty, unit_price) VALUES (\(i + 1), \(i % max(1, prods.count) + 1), \(1 + i % 3), \(Double(19 + i * 37 % 400) + 0.9))")
        }
        return out
    }
}

/// Users and grants
struct UsersView: View {
    let ws: Workspace
    @Bindable var tab: UsersTab
    @Environment(\.oaMac) private var t

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(tab.admin?.objectsAreSchemas == true ? L.t("users.accounts") : L.t("users.roles")) .font(OAMacFont.sans(12, .semibold)).foregroundStyle(t.text2)
                    Text("(\(tab.accounts.count))").font(OAMacFont.sans(12)).foregroundStyle(t.muted)
                    Spacer()
                    Button { tab.creating = ("", "%", "") } label: { Image(systemName: "plus") }.buttonStyle(.plain).accessibilityLabel(L.t("users.new"))
                }.padding(10)
                List(selection: Binding(get: { tab.selected }, set: { tab.selected = $0; tab.creating = nil; Task { await tab.loadGrants() } })) {
                    ForEach(tab.accounts) { a in
                        HStack(spacing: 8) {
                            Image(systemName: a.locked ? "lock" : a.attributes["SUPERUSER"] == true ? "shield" : a.attributes["LOGIN"] == false ? "person.2" : "person")
                                .foregroundStyle(t.text2).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.user).font(OAMacFont.mono(12.5)).foregroundStyle(t.text)
                                Text(subtitle(a)).font(OAMacFont.sans(11)).foregroundStyle(t.muted).lineLimit(1)
                            }
                        }.tag(a.id).accessibilityElement(children: .combine)
                    }
                }.scrollContentBackground(.hidden)
            }
            .frame(width: 240).background(t.panel)
            .overlay(alignment: .trailing) { Rectangle().fill(t.border).frame(width: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let c = tab.creating {
                        newAccount(c)
                    } else if let a = tab.account, let admin = tab.admin {
                        HStack {
                            Text(a.host.map { "\(a.user)@'\($0)'" } ?? a.user).font(OAMacFont.mono(16, .medium)).foregroundStyle(t.text)
                            Spacer()
                            if admin.objectsAreSchemas {
                                Button(a.locked ? L.t("users.unlock") : L.t("users.lock")) { tab.lock = !(tab.lock ?? a.locked) }.buttonStyle(.oa(.secondary, .small))
                            }
                            Button(L.t("users.drop") + "…") { tab.drop() }.buttonStyle(.oa(.danger, .small))
                        }
                        OAFormRow(L.t("users.newPassword"), width: 150) { SecureField(L.t("users.pwHint"), text: $tab.newPassword).textFieldStyle(.oa).frame(maxWidth: 340) }
                        if !admin.attributes.isEmpty {
                            Text(L.t("users.attrs")).font(OAMacFont.sans(12.5, .semibold)).foregroundStyle(t.text2)
                            HStack(spacing: 16) {
                                ForEach(admin.attributes, id: \.self) { k in
                                    Toggle(k, isOn: Binding(get: { tab.attributes[k] ?? false }, set: { tab.attributes[k] = $0 }))
                                }
                            }
                        }
                        Text(admin.objectsAreSchemas ? L.t("users.schemaPrivs") : L.t("users.tablePrivs", ["schema": ws.schema])).font(OAMacFont.sans(12.5, .semibold)).foregroundStyle(t.text2)
                        privTable(admin)
                        if !tab.raw.isEmpty {
                            Text(L.t("users.rawGrants")).font(OAMacFont.sans(12.5, .semibold)).foregroundStyle(t.text2)
                            Text(tab.raw.joined(separator: "\n")).font(OAMacFont.mono(11.5)).foregroundStyle(t.text2).textSelection(.enabled)
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(t.panel2, in: RoundedRectangle(cornerRadius: 8))
                        }
                    } else if ws.kind == .sqlite {
                        OANotice(.info, L.t("users.sqlite"))
                    } else {
                        Text(L.t("users.pick")).foregroundStyle(t.text2)
                    }
                }.padding(18)
            }
            .safeAreaInset(edge: .bottom) {
                if tab.creating == nil, tab.account != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L.t("users.pending")).font(OAMacFont.sans(12, .semibold)).foregroundStyle(t.text2)
                        Text(tab.pending.isEmpty ? L.t("users.noPending") : tab.pending.map { $0.shown + ";" }.joined(separator: "\n"))
                            .font(OAMacFont.mono(12)).foregroundStyle(tab.pending.isEmpty ? t.muted : t.text).textSelection(.enabled)
                            .padding(10).frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading).background(t.panel2, in: RoundedRectangle(cornerRadius: 8))
                        HStack {
                            Spacer()
                            Button(L.t("users.revert")) { Task { await tab.loadGrants() } }.buttonStyle(.oaSecondary).disabled(tab.pending.isEmpty)
                            Button(L.t("users.apply")) { tab.apply() }.buttonStyle(.oaPrimary).disabled(tab.pending.isEmpty)
                        }
                    }
                    .padding(14).background(t.panel)
                }
            }
        }
        .overlay { if tab.loading { ProgressView() } }
    }

    func subtitle(_ a: DBAccount) -> String {
        var s = a.host.map { "@ \($0)" } ?? (a.attributes["LOGIN"] == false ? L.t("users.group") : "LOGIN")
        if a.locked { s += " · " + L.t("users.locked") }
        if a.attributes["SUPERUSER"] == true { s += " · SUPERUSER" }
        return s
    }

    func privTable(_ admin: any DBUserAdmin) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .center, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    Text(admin.objectsAreSchemas ? L.t("users.schema") : L.t("users.table")).font(OAMacFont.sans(11.5, .semibold)).frame(width: 160, alignment: .leading).padding(6)
                    ForEach(admin.privileges, id: \.self) { p in Text(p).font(OAMacFont.sans(10.5, .semibold)).foregroundStyle(t.text2).frame(minWidth: 70).padding(6) }
                }
                .background(t.panel)
                ForEach(tab.objects, id: \.self) { o in
                    GridRow {
                        Text(o).font(OAMacFont.mono(12)).frame(width: 160, alignment: .leading).padding(6)
                        ForEach(admin.privileges, id: \.self) { p in
                            Toggle("", isOn: Binding(get: { tab.grants.has(o, p) }, set: { tab.grants.set(o, p, $0) }))
                                .labelsHidden().toggleStyle(.checkbox).accessibilityLabel("\(p) \(o)").padding(4)
                                .background(tab.grants.has(o, p) != tab.original.has(o, p) ? t.warnBg : .clear)
                        }
                    }
                    Divider()
                }
            }
            .background(t.panel2, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(t.border))
        }
    }

    func newAccount(_ c: (user: String, host: String, password: String)) -> some View {
        OABox(tab.admin?.objectsAreSchemas == true ? L.t("users.newAccount") : L.t("users.newRole")) {
            OAFormRow(L.t("users.name"), width: 150) { TextField("", text: Binding(get: { tab.creating?.user ?? "" }, set: { tab.creating?.user = $0 })).textFieldStyle(.oaMono) }
            if tab.admin?.objectsAreSchemas == true {
                OAFormRow(L.t("users.host"), width: 150) { TextField("%", text: Binding(get: { tab.creating?.host ?? "" }, set: { tab.creating?.host = $0 })).textFieldStyle(.oaMono) }
            }
            OAFormRow(L.t("users.password"), width: 150) { SecureField("", text: Binding(get: { tab.creating?.password ?? "" }, set: { tab.creating?.password = $0 })).textFieldStyle(.oa) }
            HStack {
                Spacer()
                Button(L.t("cancel")) { tab.creating = nil }.buttonStyle(.oaSecondary)
                Button(L.t("users.create")) { tab.create() }.buttonStyle(.oaPrimary).disabled(c.user.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// Schema sync and compare (5 steps)
struct SyncView: View {
    let ws: Workspace
    @Bindable var tab: SyncTab
    @Environment(\.oaMac) private var t
    private var store: ConnectionStore { .shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(L.t("sync.source")).font(OAMacFont.sans(12)).foregroundStyle(t.text2)
                Picker("", selection: Binding(get: { tab.sourceConn ?? "" }, set: { tab.sourceConn = $0; Task { await tab.loadSourceSchemas() } })) {
                    ForEach(store.items.filter { !$0.kind.isFile || $0.id == ws.conn?.id || true }) { Text($0.displayName).tag($0.id) }
                }.labelsHidden().frame(width: 170)
                if !tab.sourceSchemas.isEmpty, (store.connection(tab.sourceConn ?? "")?.kind.isFile ?? true) == false {
                    Picker("", selection: $tab.sourceSchema) { ForEach(tab.sourceSchemas, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 130)
                }
                Image(systemName: "arrow.right").foregroundStyle(t.muted)
                Text(L.t("sync.target")).font(OAMacFont.sans(12)).foregroundStyle(t.text2)
                Text(ws.conn?.displayName ?? "").font(OAMacFont.sans(12.5, .medium))
                if !ws.kind.isFile {
                    Picker("", selection: $tab.targetSchema) { ForEach(ws.schemas, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 130)
                }
                if ws.isProduction { OAStatusPill(.production, L.t("conn.tag.production").uppercased(with: L.l10n.locale)) }
                Spacer()
                Button(L.t("sync.compare")) { Task { await tab.compare() } }.buttonStyle(.oaPrimary).disabled(tab.busy || tab.sourceConn == nil)
            }
            .padding(.horizontal, 12).frame(height: 46).background(t.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(t.border).frame(height: 1) }
            .task { await tab.loadSourceSchemas() }

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(SyncTab.Step.allCases, id: \.self) { s in
                        HStack(spacing: 8) {
                            ZStack {
                                Circle().fill(s.rawValue < tab.step.rawValue ? t.ok : s == tab.step ? t.accent : t.panel2).frame(width: 20, height: 20)
                                if s.rawValue < tab.step.rawValue { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(t.accentInk) } else { Text("\(s.rawValue + 1)").font(OAMacFont.sans(11, .semibold)).foregroundStyle(s == tab.step ? t.accentInk : t.text2) }
                            }
                            Text(L.t("sync.step.\(["source", "retrieve", "changes", "review", "apply"][s.rawValue])")).font(OAMacFont.sans(12.5, s == tab.step ? .semibold : .regular)).foregroundStyle(s.rawValue <= tab.step.rawValue ? t.text : t.muted)
                        }
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(s == tab.step ? t.accentBg : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }
                    Spacer()
                }
                .padding(10).frame(width: 190).background(t.panel)
                .overlay(alignment: .trailing) { Rectangle().fill(t.border).frame(width: 1) }

                switch tab.step {
                case .source:
                    OAEmptyState(icon: "diff", title: L.t("sync.title"), text: L.t("sync.leadMac")) { EmptyView() }
                case .retrieve:
                    VStack { ProgressView(); Text(L.t("sync.readingShort")).foregroundStyle(t.text2) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                case .changes, .review:
                    changesView
                case .apply:
                    VStack(alignment: .leading, spacing: 12) {
                        if tab.busy { ProgressView(L.t("sync.applying")) }
                        if let r = tab.resultText { OANotice(tab.resultError ? .error : .ok, r) }
                        HStack {
                            Button(L.t("sync.again")) { tab.reset() }.buttonStyle(.oaSecondary)
                        }
                        Spacer()
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    var changesView: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text(L.t("sync.diffs", ["n": tab.changes.count])).font(OAMacFont.sans(12.5, .semibold))
                    Text("· " + L.t("sync.selectedN", ["n": tab.changes.filter(\.selected).count])).font(OAMacFont.sans(12)).foregroundStyle(t.text2)
                    Spacer()
                }.padding(10)
                if tab.changes.isEmpty {
                    OAEmptyState(icon: "check", title: L.t("sync.same"), text: "") { EmptyView() }
                } else {
                    List(selection: $tab.selectedChange) {
                        ForEach($tab.changes) { $c in
                            HStack(spacing: 8) {
                                Toggle("", isOn: $c.selected).labelsHidden().accessibilityLabel(L.t("sync.include", ["name": c.object]))
                                Text(L.t("kind.\(c.kind.rawValue)")).font(OAMacFont.sans(11, .semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                                    .background((c.kind == .dropTable || c.kind == .dropView ? t.danger : c.kind == .createTable || c.kind == .createView ? t.ok : t.warn).opacity(0.22), in: Capsule())
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.object).font(OAMacFont.mono(12.5))
                                    Text(c.details.map(SyncTab.detailText).joined(separator: " · ")).font(OAMacFont.sans(11)).foregroundStyle(t.text2).lineLimit(1)
                                }
                                Spacer()
                                Text(L.t("risk.\(["low", "medium", "high"][c.risk.rawValue])")).font(OAMacFont.sans(11, .medium))
                                    .foregroundStyle(c.risk == .high ? t.danger : c.risk == .medium ? t.warn : t.ok)
                            }.tag(c.id)
                        }
                    }.scrollContentBackground(.hidden)
                }
                if !ws.dialect.transactionalDDL { OANotice(.warn, L.t("sync.mysqlNote")).padding(10) }
                HStack {
                    Text(L.t("sync.stepN", ["n": tab.step.rawValue + 1])).font(OAMacFont.sans(12)).foregroundStyle(t.text2)
                    Spacer()
                    if tab.step == .review {
                        Button(L.t("sync.back")) { tab.step = .changes }.buttonStyle(.oaSecondary)
                        Button(L.t("sync.openScript")) { ws.newQueryTab(sql: scriptText(tab.script), title: L.t("sync.title")) }.buttonStyle(.oaSecondary)
                        Button(L.t("sync.apply", ["name": ws.conn?.displayName ?? ""])) { tab.apply() }.buttonStyle(.oaPrimary).disabled(tab.script.isEmpty)
                    } else {
                        Button(L.t("sync.nextReview")) { tab.step = .review }.buttonStyle(.oaPrimary).disabled(tab.changes.filter(\.selected).isEmpty)
                    }
                }.padding(10).background(t.panel)
            }
            .frame(minWidth: 420)
            .overlay(alignment: .trailing) { Rectangle().fill(t.border).frame(width: 1) }

            VStack(alignment: .leading, spacing: 8) {
                if tab.step == .review {
                    Text(L.t("sync.reviewLead", ["n": tab.script.count])).font(OAMacFont.sans(12)).foregroundStyle(t.text2)
                    ScrollView([.vertical, .horizontal]) { Text(scriptText(tab.script)).font(OAMacFont.mono(12)).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading) }
                        .background(t.panel2, in: RoundedRectangle(cornerRadius: 8))
                } else if let c = tab.changes.first(where: { $0.id == tab.selectedChange }) {
                    Text(c.object).font(OAMacFont.mono(13, .medium)) + Text("  · " + L.t("sync.sideBySide")).font(OAMacFont.sans(12)).foregroundColor(t.text2)
                    HStack(alignment: .top, spacing: 8) {
                        side(L.t("sync.source"), c.sourceTable.map { scriptText(ws.dialect.createTable($0)) } ?? c.sourceView?.sql ?? "–")
                        side(L.t("sync.target"), c.targetTable.map { scriptText(ws.dialect.createTable($0)) } ?? c.targetView?.sql ?? "–")
                    }
                    Text(L.t("sync.changeSql")).font(OAMacFont.sans(12, .semibold)).foregroundStyle(t.text2)
                    Text(scriptText(c.sql)).font(OAMacFont.mono(12)).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(t.panel2, in: RoundedRectangle(cornerRadius: 8))
                }
                Spacer()
            }
            .padding(12).frame(minWidth: 380)
        }
    }

    func side(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(OAMacFont.sans(11.5)).foregroundStyle(t.muted)
            ScrollView([.vertical, .horizontal]) { Text(text).font(OAMacFont.mono(11.5)).textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(minHeight: 160, maxHeight: 300)
                .background(t.panel2, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// History and saved queries
struct HistoryView: View {
    let ws: Workspace
    @Bindable var tab: HistoryTab
    @Environment(\.oaMac) private var t
    private var lib: QueryLibrary { .shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                OASegmented([(0, L.t("history.title")), (1, L.t("saved.title"))], selection: $tab.section).frame(width: 300)
                TextField(L.t("history.search"), text: $tab.search).textFieldStyle(.oa).frame(maxWidth: 260)
                if tab.section == 0 { Toggle(L.t("history.onlyThis"), isOn: $tab.onlyThis) }
                Spacer()
                if tab.section == 0 { Button(L.t("history.clear")) { lib.clearHistory() }.buttonStyle(.oa(.secondary, .small)).disabled(lib.history.isEmpty) }
            }
            .padding(.horizontal, 12).frame(height: 44).background(t.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(t.border).frame(height: 1) }

            let q = tab.search.lowercased()
            if tab.section == 0 {
                let items = lib.history.filter { (!tab.onlyThis || $0.connectionID == ws.conn?.id) && (q.isEmpty || $0.sql.lowercased().contains(q)) }
                if items.isEmpty {
                    OAEmptyState(icon: "clock", title: L.t("history.emptyTitle"), text: L.t("history.empty")) { EmptyView() }
                } else {
                    List {
                        ForEach(items) { h in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(h.sql).font(OAMacFont.mono(12)).lineLimit(3).foregroundStyle(h.error == nil ? t.text : t.danger)
                                HStack(spacing: 8) {
                                    Text(L.l10n.dateTime(h.date))
                                    Text(h.connectionName)
                                    Text(L.l10n.ms(h.ms))
                                    if let r = h.rows { Text(L.t("history.rows", ["n": r])) }
                                    if let e = h.error { Text(e).foregroundStyle(t.danger).lineLimit(1) }
                                }.font(OAMacFont.sans(11)).foregroundStyle(t.muted)
                            }
                            .padding(.vertical, 3)
                            .contextMenu {
                                Button(L.t("history.open")) { ws.newQueryTab(sql: h.sql) }
                                Button(L.t("kit_copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(h.sql, forType: .string) }
                                Button(L.t("history.delete"), role: .destructive) { lib.deleteHistory(h.id) }
                            }
                            .onTapGesture(count: 2) { ws.newQueryTab(sql: h.sql) }
                            .accessibilityAction(named: L.t("history.open")) { ws.newQueryTab(sql: h.sql) }
                        }
                    }.scrollContentBackground(.hidden)
                }
            } else {
                let items = lib.saved.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.sql.lowercased().contains(q) }
                if items.isEmpty {
                    OAEmptyState(icon: "bookmark", title: L.t("saved.emptyTitle"), text: L.t("saved.empty")) { EmptyView() }
                } else {
                    List {
                        ForEach(items) { s in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.name).font(OAMacFont.sans(13, .medium))
                                Text(s.sql).font(OAMacFont.mono(11.5)).foregroundStyle(t.text2).lineLimit(2)
                            }
                            .padding(.vertical, 3)
                            .contextMenu {
                                Button(L.t("saved.open")) { let tb = ws.newQueryTab(sql: s.sql, title: s.name); tb.savedQueryID = s.id }
                                Button(L.t("saved.delete"), role: .destructive) { lib.deleteSaved(s.id) }
                            }
                            .onTapGesture(count: 2) { let tb = ws.newQueryTab(sql: s.sql, title: s.name); tb.savedQueryID = s.id }
                        }
                    }.scrollContentBackground(.hidden)
                }
            }
        }
    }
}

/// Save the query (⌘D)
struct SaveQuerySheet: View {
    let ws: Workspace
    let tab: QueryTab
    @State private var name = ""
    @State private var onlyThis = true
    let done: () -> Void
    var body: some View {
        OASheet(L.t("saved.saveTitle")) {
            VStack(alignment: .leading, spacing: 10) {
                TextField(L.t("saved.name"), text: $name).textFieldStyle(.oa).frame(width: 380)
                Toggle(L.t("saved.onlyThis"), isOn: $onlyThis)
            }
        } footer: {
            Spacer()
            Button(L.t("cancel"), action: done).buttonStyle(.oaSecondary).keyboardShortcut(.cancelAction)
            Button(L.t("save")) {
                let q = SavedQuery(id: tab.savedQueryID ?? DBID.make(), name: name, sql: tab.sql, connectionID: onlyThis ? ws.conn?.id : nil)
                QueryLibrary.shared.save(q)
                tab.savedQueryID = q.id
                tab.savedSQL = tab.sql
                tab.title = name
                ws.toasts.show(L.t("saved", ["name": name]))
                done()
            }.buttonStyle(.oaPrimary).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear { name = tab.savedQueryID.flatMap { id in QueryLibrary.shared.saved.first { $0.id == id }?.name } ?? tab.title }
    }
}

/// CSV import: file, column mapping, INSERT (in one transaction)
struct ImportSheet: View {
    let ws: Workspace
    let table: String
    let done: () -> Void
    @State private var rows: [[String]] = []
    @State private var header = true
    @State private var mapping: [Int: String] = [:]
    @State private var fileName = ""
    @State private var busy = false
    @Environment(\.oaMac) private var t

    var columns: [String] { ws.tableInfo[table]?.columns.map(\.name) ?? [] }
    var body: some View {
        OASheet(L.t("import.title", ["table": table]), subtitle: fileName.isEmpty ? L.t("import.lead") : fileName) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button(L.t("import.pick")) { pick() }.buttonStyle(.oaSecondary)
                    Toggle(L.t("import.header"), isOn: $header)
                    Spacer()
                    if !rows.isEmpty { Text(L.t("import.rows", ["n": rows.count - (header ? 1 : 0)])).foregroundStyle(t.text2) }
                }
                if let first = rows.first {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(first.enumerated()), id: \.offset) { i, h in
                                HStack {
                                    Text(header ? h : L.t("import.colN", ["n": i + 1])).font(OAMacFont.mono(12)).frame(width: 180, alignment: .leading)
                                    Image(systemName: "arrow.right").foregroundStyle(t.muted)
                                    Picker("", selection: Binding(get: { mapping[i] ?? "" }, set: { mapping[i] = $0 })) {
                                        Text(L.t("import.skip")).tag("")
                                        ForEach(columns, id: \.self) { Text($0).tag($0) }
                                    }.labelsHidden().frame(width: 200)
                                    Text(rows.dropFirst(header ? 1 : 0).first.map { i < $0.count ? $0[i] : "" } ?? "").font(OAMacFont.mono(11)).foregroundStyle(t.muted).lineLimit(1)
                                }
                            }
                        }
                    }.frame(height: 260)
                }
            }
        } footer: {
            Spacer()
            Button(L.t("cancel"), action: done).buttonStyle(.oaSecondary).keyboardShortcut(.cancelAction)
            Button(L.t("import.run")) { run() }.buttonStyle(.oaPrimary).keyboardShortcut(.defaultAction).disabled(rows.isEmpty || mapping.values.allSatisfy(\.isEmpty) || busy)
        }
        .frame(width: 680)
    }

    func pick() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        guard p.runModal() == .OK, let url = p.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        fileName = url.lastPathComponent
        rows = Exporter.parseCSV(text)
        mapping = [:]
        if let h = rows.first { for (i, n) in h.enumerated() { if let c = columns.first(where: { $0.lowercased() == n.lowercased().trimmingCharacters(in: .whitespaces) }) { mapping[i] = c } } }
    }

    func run() {
        let d = ws.dialect
        let data = header ? Array(rows.dropFirst()) : rows
        let pairs = mapping.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }
        let sqls = data.map { r in
            d.editSQL(.insert(values: Dictionary(uniqueKeysWithValues: pairs.map { ($0.value, $0.key < r.count ? DBValue.text(r[$0.key]) : .null) })),
                      schema: ws.kind.isFile ? nil : ws.schema, table: table, order: pairs.map(\.value))
        }
        busy = true
        ws.guardWrite(sqls) {
            Task {
                let r = await ws.runScript(sqls, transactional: true)
                busy = false
                if let e = r.error { ws.toasts.show(L.t("import.failed", ["msg": e]), .error) } else {
                    ws.toasts.show(L.t("import.done", ["n": r.done]))
                    if let tt = ws.tabs.first(where: { ($0 as? TableTab)?.table == table }) as? TableTab { await tt.reloadData() }
                    done()
                }
            }
        }
    }
}
