import AppKit
import SwiftUI
import OpenAsyMacKit

/// A window's state: one connection with tabs inside (query, table, users, sync, history). Another connection opens in
/// a new window (it can join as a macOS tab).
@MainActor @Observable
final class Workspace {
    enum State: Equatable { case idle, connecting, connected, failed(String) }

    let connectionID: String?
    var conn: SavedConnection?
    private(set) var session: (any DBSession)?
    var state: State = .idle
    var schemas: [String] = []
    var schema: String = ""
    var objects = DBObjectList()
    /// For completion and structure: the definitions of the schema's tables (read in the background)
    var tableInfo: [String: DBTable] = [:]
    var tabs: [WorkTab] = []
    var selectedTab: String?
    var inTransaction = false
    var pendingTxStatements = 0
    var sidebarFilter = ""
    var showInspector = true
    var showSidebar = true
    let toasts = OAToastCenter()
    /// What to ask while connecting (password, SSH fingerprint)
    var prompt: Prompt?
    var editingConnection: SavedConnection?
    var showSaveQuery = false
    var importTable: String?
    /// When the grid selection changes the inspector refreshes
    var selectionTick = 0
    var confirm: Confirm?
    private var openedURLs: [URL] = []

    enum Prompt: Identifiable, Equatable {
        case password(String)
        case fingerprint(host: String, port: Int, fingerprint: String)
        var id: String { switch self { case .password(let n): "pw\(n)"; case .fingerprint(_, _, let f): f } }
    }

    struct Confirm: Identifiable {
        let id = UUID()
        var title: String
        var text: String
        var action: String
        var destructive: Bool
        var run: () -> Void
    }

    init(connectionID: String?) {
        self.connectionID = connectionID
        conn = connectionID.flatMap { ConnectionStore.shared.connection($0) }
    }

    var dialect: any SQLDialect { session?.dialect ?? DBEngines.dialect(for: conn?.kind ?? .postgres) }
    var kind: DBKind { session?.kind ?? conn?.kind ?? .postgres }
    var isConnected: Bool { state == .connected }
    var selected: WorkTab? { tabs.first { $0.id == selectedTab } }
    var isProduction: Bool { conn?.tag == .production }

    // MARK: Connection

    func connect(password: String? = nil, sshSecret: String? = nil) async {
        guard let c = conn, state != .connecting else { return }
        state = .connecting
        do {
            let (cfg, urls) = try ConnectionStore.shared.config(for: c, password: password, sshSecret: sshSecret)
            openedURLs += urls
            // When the password is not saved, it is asked for on every connection
            if !c.kind.isFile, password == nil, !c.savePassword, !c.user.isEmpty { state = .idle; prompt = .password(c.displayName); return }
            let s = try await DBEngines.connect(cfg)
            session = s
            if let f = s.sshFingerprint, c.sshEnabled { ConnectionStore.shared.knownHosts.trust(host: c.sshHost, port: c.sshPort, fingerprint: f) }
            state = .connected
            ConnectionStore.shared.touch(c.id)
            await loadSchemas()
            await LinkRouter.shared.apply(to: self)   // "open" and "query" requests from OpenAsy Schema
            if tabs.isEmpty { newQueryTab() }
        } catch OASSHError.unknownHost(let f) {
            state = .idle
            prompt = .fingerprint(host: c.sshHost, port: c.sshPort, fingerprint: f)
        } catch {
            state = .failed(L.err(error))
            LinkRouter.shared.discard(c.id)
        }
    }

    /// Confirm the SSH fingerprint and connect again
    func trust(_ host: String, _ port: Int, _ f: String) async {
        ConnectionStore.shared.knownHosts.trust(host: host, port: port, fingerprint: f)
        prompt = nil
        await connect()
    }

    func disconnect() async {
        await session?.close()
        session = nil
        state = .idle
        inTransaction = false
        for u in openedURLs { u.stopAccessingSecurityScopedResource() }
        openedURLs = []
    }

    func loadSchemas() async {
        guard let s = session else { return }
        do {
            schemas = try await s.dialect.listSchemas(s)
            let cur = try await s.dialect.currentSchema(s)
            let want = conn?.defaultSchema ?? ""
            schema = !want.isEmpty && schemas.contains(want) ? want : (schemas.contains(cur) ? cur : (schemas.first ?? cur))
            if s.kind == .mysql || s.kind == .mariadb, !schema.isEmpty, schema != cur { _ = try? await s.execute("USE \(s.dialect.q(schema))") }
            await reloadObjects()
        } catch { toasts.show(L.t("err.read", ["msg": L.err(error)]), .error) }
    }

    func selectSchema(_ name: String) async {
        guard let s = session, name != schema else { return }
        schema = name
        if s.kind == .mysql || s.kind == .mariadb { _ = try? await s.execute("USE \(s.dialect.q(name))") }
        if s.kind == .postgres || s.kind == .redshift { _ = try? await s.execute("SET search_path TO \(s.dialect.q(name))") }
        tableInfo = [:]
        await reloadObjects()
    }

    func reloadObjects() async {
        guard let s = session else { return }
        do {
            objects = try await s.dialect.listObjects(s, schema: schema)
            Task { await loadTableInfo() }
        } catch { toasts.show(L.t("err.read", ["msg": L.err(error)]), .error) }
    }

    /// Columns of every table (completion); in the background for a large schema
    func loadTableInfo() async {
        guard let s = session else { return }
        if let all = try? await s.dialect.introspect(s, schema: schema) {
            tableInfo = Dictionary(all.tables.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    // MARK: Tabs

    @discardableResult
    func newQueryTab(sql: String = "", title: String? = nil) -> QueryTab {
        let n = tabs.filter { $0 is QueryTab }.count + 1
        let t = QueryTab(ws: self, title: title ?? L.t("query.tabTitle", ["n": n]), sql: sql)
        tabs.append(t)
        selectedTab = t.id
        return t
    }

    func openTable(_ name: String, mode: TableTab.Mode = .data) {
        if let t = tabs.first(where: { ($0 as? TableTab)?.table == name && ($0 as? TableTab)?.schema == schema }) as? TableTab {
            t.mode = mode
            selectedTab = t.id
            return
        }
        let t = TableTab(ws: self, schema: schema, table: name, mode: mode)
        tabs.append(t)
        selectedTab = t.id
        Task { await t.load() }
    }

    func openSingleton<T: WorkTab>(_ type: T.Type, make: () -> T) {
        if let t = tabs.first(where: { $0 is T }) { selectedTab = t.id; return }
        let t = make()
        tabs.append(t)
        selectedTab = t.id
    }

    func close(_ id: String) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let t = tabs[i]
        if t.isDirty {
            confirm = Confirm(title: L.t("tab.closeDirty.title"), text: L.t("tab.closeDirty.text", ["name": t.title]), action: L.t("tab.closeDirty.discard"), destructive: true) { [weak self] in
                self?.remove(id)
            }
            return
        }
        remove(id)
    }

    private func remove(_ id: String) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: i)
        if selectedTab == id { selectedTab = tabs.isEmpty ? nil : tabs[max(0, i - 1)].id }
    }

    func cycleTab(_ d: Int) {
        guard !tabs.isEmpty, let i = tabs.firstIndex(where: { $0.id == selectedTab }) else { return }
        selectedTab = tabs[(i + d + tabs.count) % tabs.count].id
    }

    // MARK: Running

    /// Runs a statement: read-only and production checks, transaction state, the history entry
    func execute(_ sql: String, maxRows: Int? = nil, record: Bool = true) async throws -> DBResult {
        guard let s = session else { throw DBError(L.t("query.noConn")) }
        if conn?.readOnly == true, SQLText.isWrite(sql) { throw DBError(L.t("query.readOnly")) }
        let t0 = Date()
        do {
            let r = try await s.execute(sql, maxRows: maxRows ?? AppSettings.shared.maxRows)
            switch SQLText.transactionKind(sql) {
            case .begin: inTransaction = true; pendingTxStatements = 0
            case .commit, .rollback: inTransaction = false; pendingTxStatements = 0
            case nil: if inTransaction, SQLText.isWrite(sql) { pendingTxStatements += 1 }
            }
            if record { QueryLibrary.shared.record(HistoryEntry(connectionID: conn?.id ?? "", connectionName: conn?.displayName ?? "", sql: sql, ms: r.ms, rows: r.isResultSet ? r.rows.count : r.affected)) }
            return r
        } catch {
            if record { QueryLibrary.shared.record(HistoryEntry(connectionID: conn?.id ?? "", connectionName: conn?.displayName ?? "", sql: sql, ms: Date().timeIntervalSince(t0) * 1000, error: L.err(error))) }
            throw error
        }
    }

    /// Several statements in turn (in one transaction when not already in one and the system supports it)
    func runScript(_ statements: [String], transactional: Bool) async -> (done: Int, error: String?) {
        var done = 0
        let wrap = transactional && !inTransaction
        do {
            if wrap { _ = try await execute(kind == .mysql || kind == .mariadb ? "START TRANSACTION" : "BEGIN", record: false) }
            for s in statements {
                _ = try await execute(s)
                done += 1
            }
            if wrap { _ = try await execute("COMMIT", record: false) }
            return (done, nil)
        } catch {
            if wrap { _ = try? await execute("ROLLBACK", record: false) }
            return (done, L.err(error))
        }
    }

    func beginTransaction() async {
        do { _ = try await execute(kind == .mysql || kind == .mariadb ? "START TRANSACTION" : "BEGIN") } catch { toasts.show(L.err(error), .error) }
    }
    func commit() async {
        do { _ = try await execute("COMMIT"); toasts.show(L.t("tx.committed")) } catch { toasts.show(L.err(error), .error) }
    }
    func rollback() async {
        do { _ = try await execute("ROLLBACK"); toasts.show(L.t("tx.rolledBack"), .info) } catch { toasts.show(L.err(error), .error) }
    }

    /// Before a change: confirmation on production
    func guardWrite(_ sqls: [String], run: @escaping () -> Void) {
        if isProduction, AppSettings.shared.confirmWrites, sqls.contains(where: SQLText.isWrite) {
            confirm = Confirm(title: L.t("prod.title"), text: L.t("prod.text", ["name": conn?.displayName ?? ""]), action: L.t("prod.run"), destructive: true, run: run)
        } else { run() }
    }
}

/// The common base of tab types
@MainActor @Observable
class WorkTab: Identifiable {
    let id = DBID.make()
    weak var ws: Workspace?
    var title: String
    init(ws: Workspace, title: String) { self.ws = ws; self.title = title }
    var icon: String { "code" }
    var isDirty: Bool { false }
}
