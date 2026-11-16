import AppKit
import SwiftUI
import OpenAsyMacKit

/// Users and grants
@MainActor @Observable
final class UsersTab: WorkTab {
    var accounts: [DBAccount] = []
    var selected: String?
    var objects: [String] = []
    var original = DBGrantSet()
    var grants = DBGrantSet()
    var attributes: [String: Bool] = [:]
    var raw: [String] = []
    var newPassword = ""
    var lock: Bool?
    var loading = false
    var creating: (user: String, host: String, password: String)?

    init(ws: Workspace) { super.init(ws: ws, title: L.t("users.title")) }
    override var icon: String { "users" }
    var admin: (any DBUserAdmin)? { ws?.dialect.userAdmin }
    var account: DBAccount? { accounts.first { $0.id == selected } }
    override var isDirty: Bool { !pending.isEmpty }

    func load() async {
        guard let ws, let s = ws.session, let admin else { return }
        loading = true
        do {
            accounts = try await admin.accounts(s)
            objects = admin.objectsAreSchemas ? ws.schemas : ws.objects.tables.map(\.name)
            if selected == nil || account == nil { selected = accounts.first?.id }
            await loadGrants()
        } catch { ws.toasts.show(L.t("users.err", ["msg": L.err(error)]), .error) }
        loading = false
    }

    func loadGrants() async {
        guard let ws, let s = ws.session, let admin, let a = account else { return }
        do {
            original = try await admin.grants(s, account: a, schema: ws.schema)
            grants = original
            raw = (try? await admin.rawGrants(s, account: a)) ?? []
            attributes = a.attributes
            newPassword = ""
            lock = nil
        } catch { ws.toasts.show(L.t("users.err", ["msg": L.err(error)]), .error) }
    }

    var pending: [DBMaskedStatement] {
        guard let admin, let a = account, let ws else { return [] }
        return admin.changes(account: a, schema: ws.schema, objects: objects, from: original, to: grants, attributes: attributes,
                             newPassword: newPassword.isEmpty ? nil : newPassword, lock: lock)
    }

    func apply(_ list: [DBMaskedStatement]? = nil) {
        guard let ws else { return }
        let st = list ?? pending
        guard !st.isEmpty else { return }
        ws.guardWrite(st.map(\.real)) { [weak self] in
            Task {
                let r = await ws.runScript(st.map(\.real), transactional: false)
                if let e = r.error { ws.toasts.show(L.t("users.err", ["msg": e]), .error) } else { ws.toasts.show(L.t("users.applied", ["n": r.done])) }
                self?.creating = nil
                await self?.load()
            }
        }
    }

    func create() {
        guard let c = creating, let admin, !c.user.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        apply([admin.create(user: c.user.trimmingCharacters(in: .whitespaces), host: c.host.isEmpty ? "%" : c.host, password: c.password)])
        selected = c.host.isEmpty || admin.objectsAreSchemas == false ? c.user : "\(c.user)@\(c.host)"
    }

    func drop() {
        guard let ws, let a = account, let admin else { return }
        ws.confirm = .init(title: L.t("users.drop"), text: L.t("users.dropQ", ["name": a.id]), action: L.t("users.drop"), destructive: true) { [weak self] in
            self?.apply([DBMaskedStatement(shown: admin.drop(a), real: admin.drop(a))])
            self?.selected = nil
        }
    }
}

/// Schema sync and compare: two connections or two schemas. The source is the wanted state, the target the side that
/// changes.
@MainActor @Observable
final class SyncTab: WorkTab {
    enum Step: Int, CaseIterable { case source, retrieve, changes, review, apply }
    var step: Step = .source
    var sourceConn: String?
    var sourceSchema = ""
    var targetSchema = ""
    var sourceSchemas: [String] = []
    var changes: [DBChange] = []
    var selectedChange: String?
    var filter: Int = 0
    var busy = false
    var resultText: String?
    var resultError = false
    private var sourceSession: (any DBSession)?
    var sourceKind: DBKind?

    init(ws: Workspace) {
        super.init(ws: ws, title: L.t("sync.title"))
        sourceConn = ws.conn?.id
        targetSchema = ws.schema
        sourceSchema = ws.schema
    }
    override var icon: String { "diff" }

    var targetDialect: any SQLDialect { ws?.dialect ?? PostgresDialect() }
    var script: [String] { DBDiff.script(targetDialect, schema: targetSchema, changes: changes) }

    /// The source connection's schemas (the window's session is used for the same connection)
    func loadSourceSchemas() async {
        guard let ws else { return }
        if sourceConn == ws.conn?.id { sourceSchemas = ws.schemas; sourceKind = ws.kind; return }
        do {
            let s = try await openSource()
            sourceSchemas = try await s.dialect.listSchemas(s)
            if !sourceSchemas.contains(sourceSchema) { sourceSchema = (try? await s.dialect.currentSchema(s)) ?? sourceSchemas.first ?? "" }
        } catch { ws.toasts.show(L.t("err.connect", ["name": "", "msg": L.err(error)]), .error) }
    }

    private func openSource() async throws -> any DBSession {
        guard let ws else { throw DBError("") }
        if sourceConn == ws.conn?.id, let s = ws.session { return s }
        if let s = sourceSession { return s }
        guard let id = sourceConn, let c = ConnectionStore.shared.connection(id) else { throw DBError("no source") }
        let (cfg, _) = try ConnectionStore.shared.config(for: c, password: nil, sshSecret: nil)
        let s = try await DBEngines.connect(cfg)
        sourceSession = s
        sourceKind = s.kind
        return s
    }

    func compare() async {
        guard let ws, let target = ws.session else { return }
        busy = true
        step = .retrieve
        do {
            let src = try await openSource()
            let a = try await src.dialect.introspect(src, schema: sourceSchema)
            let b = try await target.dialect.introspect(target, schema: targetSchema)
            changes = DBDiff.compare(target.dialect, source: a, target: b)
            selectedChange = changes.first?.id
            step = .changes
        } catch {
            ws.toasts.show(L.t("err.read", ["msg": L.err(error)]), .error)
            step = .source
        }
        busy = false
    }

    func apply() {
        guard let ws else { return }
        let sqls = changes.filter(\.selected).flatMap(\.sql)
        guard !sqls.isEmpty else { return }
        ws.guardWrite(sqls) { [weak self] in
            guard let self else { return }
            busy = true
            step = .apply
            Task {
                let use = ws.dialect.useSchema(self.targetSchema).map { [$0] } ?? []
                if let u = use.first { _ = try? await ws.execute(u, record: false) }
                let r = await ws.runScript(sqls, transactional: ws.dialect.transactionalDDL)
                self.busy = false
                self.resultError = r.error != nil
                self.resultText = r.error.map { L.t("sync.failed", ["done": r.done, "total": sqls.count]) + "\n" + $0 } ?? L.t("sync.done", ["n": r.done])
                await ws.reloadObjects()
            }
        }
    }

    func reset() { step = .source; changes = []; resultText = nil }

    static func detailText(_ d: DBChange.Detail) -> String {
        switch d {
        case .addColumn(let n): L.t("detail.addColumn", ["name": n])
        case .dropColumn(let n): L.t("detail.dropColumn", ["name": n])
        case .renameColumn(let a, let b): L.t("detail.renameColumn", ["from": a, "to": b])
        case .changeColumn(let n, let a, let b): L.t("detail.changeColumn", ["name": n, "from": a, "to": b])
        case .primaryKey(let a, let b): L.t("detail.primaryKey", ["from": a.isEmpty ? "–" : a, "to": b.isEmpty ? "–" : b])
        case .addIndex(let n): L.t("detail.addIndex", ["name": n])
        case .dropIndex(let n): L.t("detail.dropIndex", ["name": n])
        case .addFk(let n): L.t("detail.addFk", ["name": n])
        case .dropFk(let n): L.t("detail.dropFk", ["name": n])
        case .comment: L.t("detail.comment")
        case .renameTable(let a, let b): L.t("detail.renameTable", ["from": a, "to": b])
        }
    }
}

/// History and saved queries
@MainActor @Observable
final class HistoryTab: WorkTab {
    var search = ""
    var onlyThis = true
    var section: Int = 0
    init(ws: Workspace) { super.init(ws: ws, title: L.t("history.title")) }
    override var icon: String { "clock" }
}
