import AppKit
import SwiftUI
import OpenAsyMacKit

/// Table tab: Data (filters, sorting, endless scrolling, pending changes), Structure (editing columns, indexes and
/// foreign keys, SQL preview), the CREATE statement.
@MainActor @Observable
final class TableTab: WorkTab, OADataGridSource {
    enum Mode: String, CaseIterable { case data, structure, ddl }

    let schema: String
    let table: String
    var mode: Mode
    var info: DBTable?
    var isView = false
    var ddl = ""
    var loadError: String?

    // Data
    var columns: [DBResultColumn] = []
    var rows: [[DBValue]] = []
    var rowIDs: [DBValue?] = []
    var total: Int64?
    var filters: [DBFilter] = []
    var sort: (column: Int, ascending: Bool)?
    var loading = false
    var exhausted = false
    var lastMs: Double = 0
    var edits: [Int: [String: DBValue]] = [:]
    var deleted: Set<Int> = []
    var inserted: [[String: DBValue]] = []
    var selectedRows = IndexSet()
    var selectedColumn: Int?
    var version = 0
    @ObservationIgnored var requested: IndexSet?
    var gridRequestedSelection: IndexSet? { defer { requested = nil }; return requested }
    var showPreview = false
    var committing = false

    // Structure
    var draft: DBTable?
    var selectedField: String?
    var showStructurePreview = false

    init(ws: Workspace, schema: String, table: String, mode: Mode) {
        self.schema = schema; self.table = table; self.mode = mode
        super.init(ws: ws, title: table)
    }

    override var icon: String { isView ? "view" : "table" }
    override var isDirty: Bool { hasDataChanges || hasStructureChanges }
    var hasDataChanges: Bool { !edits.isEmpty || !deleted.isEmpty || !inserted.isEmpty }
    var hasStructureChanges: Bool { !structureSQL.isEmpty }
    var dialect: any SQLDialect { ws?.dialect ?? SQLiteDialect() }
    var editable: Bool { !isView && ws?.conn?.readOnly != true && (info.map { !$0.columns.isEmpty } ?? false) }
    var usesRowIdentity: Bool { (info?.primaryKey.isEmpty ?? true) && dialect.rowIdentity != nil && !isView }

    // MARK: Loading

    func load() async {
        guard let ws, let s = ws.session else { return }
        loadError = nil
        isView = ws.objects.views.contains { $0.name == table }
        do {
            info = try await s.dialect.describe(s, schema: schema, table: table)
            draft = info
            if let info { ws.tableInfo[table] = info }
            ddl = (try? await s.dialect.createSQL(s, schema: schema, table: table)) ?? ""
        } catch { loadError = L.err(error) }
        await reloadData()
    }

    func reloadData() async {
        guard let ws else { return }
        loading = true
        exhausted = false
        edits = [:]; deleted = []; inserted = []
        rows = []; rowIDs = []
        await fetch(offset: 0)
        if let c = try? await ws.execute(dialect.countSQL(schema: schema, table: table, filters: filters), record: false).rows.first?.first?.text { total = Int64(c) }
        loading = false
    }

    private func fetch(offset: Int) async {
        guard let ws else { return }
        let page = AppSettings.shared.pageSize
        let sortCol = sort.flatMap { columns.indices.contains($0.column) ? (columns[$0.column].name, $0.ascending) : nil }
        let sql = dialect.selectPage(schema: schema, table: table, filters: filters, sort: sortCol, limit: page, offset: offset, withRowIdentity: usesRowIdentity)
        do {
            let r = try await ws.execute(sql, maxRows: page, record: false)
            lastMs = r.ms
            var cols = r.columns
            var data = r.rows
            var ids: [DBValue?] = Array(repeating: nil, count: data.count)
            if let k = cols.firstIndex(where: { $0.name == DBRowIdentity.column }) {
                cols.remove(at: k)
                ids = data.map { $0[k] }
                data = data.map { var x = $0; x.remove(at: k); return x }
            }
            if offset == 0 { columns = cols }
            rows += data
            rowIDs += ids
            exhausted = data.count < page
            loadError = nil
        } catch {
            loadError = L.err(error)
            exhausted = true
        }
        version += 1
    }

    func loadMore() {
        guard !loading, !exhausted else { return }
        loading = true
        Task { await fetch(offset: rows.count); loading = false }
    }

    /// The filter or sort changed: if there are pending changes, ask first
    func requery() {
        guard let ws else { return }
        if hasDataChanges {
            ws.confirm = .init(title: L.t("data.discardQ.title"), text: L.t("data.discardQ.text"), action: L.t("data.discard"), destructive: true) { [weak self] in
                Task { await self?.reloadData() }
            }
        } else { Task { await reloadData() } }
    }

    // MARK: Grid source

    var gridColumns: [OAGridColumn] {
        columns.map { c in
            let col = info?.column(c.name)
            let ty = col?.type ?? c.type
            let byType: CGFloat = ty.contains("timestamp") || ty.contains("datetime") ? 230 : ty.contains("json") || ty.contains("text") ? 260 : 110
            return OAGridColumn(title: c.name, subtitle: ty, numeric: ResultSource.isNumeric(ty), width: max(byType, min(320, CGFloat(c.name.count + ty.count) * 8 + 40)))
        }
    }
    var gridRowCount: Int { rows.count + inserted.count }

    func gridValue(row: Int, column c: Int) -> (text: String, isNull: Bool) {
        let name = columns[c].name
        if row >= rows.count {
            let ins = inserted[row - rows.count]
            if let v = ins[name] { return (v.display, v.isNull) }
            let col = info?.column(name)
            if col?.autoInc == true { return (L.t("data.auto"), true) }
            if let d = col?.default { return ("DEFAULT " + d, true) }
            return ("NULL", true)
        }
        if let v = edits[row]?[name] { return (v.display, v.isNull) }
        let v = rows[row][c]
        return (v.display, v.isNull)
    }

    func gridCellState(row: Int, column c: Int) -> OAGridCellState {
        if row >= rows.count { return .inserted }
        if deleted.contains(row) { return .deleted }
        return edits[row]?[columns[c].name] != nil ? .edited : .normal
    }

    func gridCanEdit(row: Int, column: Int) -> Bool { editable && !deleted.contains(row) }

    func gridEdit(row: Int, column c: Int, text: String) {
        setValue(.text(text), row: row, column: c)
    }

    func setValue(_ v: DBValue, row: Int, column c: Int) {
        let name = columns[c].name
        if row >= rows.count {
            inserted[row - rows.count][name] = v
        } else if rows[row][c] == v {
            edits[row]?.removeValue(forKey: name)
            if edits[row]?.isEmpty == true { edits.removeValue(forKey: row) }
        } else {
            edits[row, default: [:]][name] = v
        }
        version += 1
    }

    func gridSelectionChanged(rows r: IndexSet, column: Int?) {
        selectedRows = r
        if let column { selectedColumn = column }
    }

    var gridSort: (column: Int, ascending: Bool)? { sort }
    func gridSortRequested(column: Int) {
        sort = (column, sort?.column == column ? !(sort!.ascending) : true)
        requery()
    }

    func gridNearEnd() { loadMore() }
    func gridDeleteRequested(rows r: IndexSet) { deleteRows(r) }
    func gridMenu(rows r: IndexSet, column: Int?) -> NSMenu? {
        let m = NSMenu()
        if editable {
            m.addItem(ClosureMenuItem(L.t("data.addRow")) { [weak self] in self?.addRow() })
            m.addItem(ClosureMenuItem(L.t("data.deleteRows")) { [weak self] in self?.deleteRows(r) })
            if let column { m.addItem(ClosureMenuItem(L.t("data.setNull")) { [weak self] in for row in r { self?.setValue(.null, row: row, column: column) } }) }
            m.addItem(.separator())
        }
        if let e = ExportMenu.make(source: self, rows: r, table: table, dialect: dialect) { for i in e.items { e.removeItem(i); m.addItem(i) } }
        return m
    }

    // MARK: Editing

    func addRow() {
        guard editable else { return }
        inserted.append([:])
        version += 1
    }

    func deleteRows(_ r: IndexSet) {
        guard editable else { return }
        for row in r.sorted(by: >) {
            if row >= rows.count { inserted.remove(at: row - rows.count) } else if deleted.contains(row) { deleted.remove(row) } else { deleted.insert(row) }
        }
        version += 1
    }

    func setNullSelected() {
        guard editable, let c = selectedColumn else { return }
        for row in selectedRows { setValue(.null, row: row, column: c) }
    }

    func key(for row: Int) -> DBRowKey {
        if let pk = info?.primaryKey, !pk.isEmpty {
            return DBRowKey(columns: pk, values: pk.map { name in columns.firstIndex { $0.name == name }.map { rows[row][$0] } ?? .null })
        }
        if usesRowIdentity, let rid = dialect.rowIdentity, let v = rowIDs[row] { return DBRowKey(columns: [rid], values: [v]) }
        return DBRowKey(columns: columns.map(\.name), values: rows[row], allColumns: true)
    }

    var pendingEdits: [DBRowEdit] {
        var out: [DBRowEdit] = []
        for row in edits.keys.sorted() where !deleted.contains(row) { out.append(.update(key: key(for: row), set: edits[row]!)) }
        for v in inserted { out.append(.insert(values: v)) }
        for row in deleted.sorted() { out.append(.delete(key: key(for: row))) }
        return out
    }

    var pendingSQL: [String] {
        let order = columns.map(\.name)
        return pendingEdits.map { dialect.editSQL($0, schema: schema, table: table, order: order) }
    }

    var counts: (edit: Int, insert: Int, delete: Int) {
        (edits.keys.filter { !deleted.contains($0) }.count, inserted.count, deleted.count)
    }

    func discard() {
        edits = [:]; deleted = []; inserted = []
        version += 1
    }

    /// Commit: pending changes in one transaction (inside the connection's open transaction, if there is one)
    func commit() {
        guard let ws, hasDataChanges, !committing else { return }
        let sqls = pendingSQL
        ws.guardWrite(sqls) { [weak self] in
            guard let self else { return }
            committing = true
            Task {
                let r = await ws.runScript(sqls, transactional: true)
                self.committing = false
                self.showPreview = false
                if let e = r.error {
                    ws.toasts.show(L.t("data.commitFailed", ["msg": e]), .error)
                } else {
                    ws.toasts.show(L.t("data.committed", ["n": r.done]))
                    await self.reloadData()
                }
            }
        }
    }

    // MARK: Structure

    var structureSQL: [String] {
        guard let info, let draft, info != draft else { return [] }
        var out: [String] = []
        if info.name != draft.name { out.append(dialect.renameTable(info.name, draft.name)) }
        var renamed = info
        renamed.name = draft.name
        out += dialect.alterTable(from: renamed, to: draft)
        return out
    }

    var structureDetails: [String] {
        guard let info, let draft else { return [] }
        return DBDiff.compare(dialect, source: DBIntrospected(tables: [draft]), target: DBIntrospected(tables: [info])).first?.details.map(SyncTab.detailText) ?? []
    }

    func applyStructure() {
        guard let ws, hasStructureChanges else { return }
        let sqls = structureSQL
        ws.guardWrite(sqls) { [weak self] in
            guard let self else { return }
            Task {
                // SQLite rebuild: foreign key checks are turned off outside the transaction
                var r: (done: Int, error: String?)
                if self.dialect.kind == .sqlite {
                    _ = try? await ws.execute("PRAGMA foreign_keys = OFF", record: false)
                    r = await ws.runScript(sqls, transactional: true)
                    _ = try? await ws.execute("PRAGMA foreign_keys = ON", record: false)
                } else {
                    r = await ws.runScript(sqls, transactional: self.dialect.transactionalDDL)
                }
                self.showStructurePreview = false
                if let e = r.error { ws.toasts.show(L.t("structure.failed", ["msg": e]), .error) } else {
                    ws.toasts.show(L.t("structure.applied", ["n": r.done]))
                    await ws.reloadObjects()
                    await self.load()
                }
            }
        }
    }

    func discardStructure() { draft = info }

    func addColumn() {
        guard var d = draft else { return }
        var n = 1
        while d.columns.contains(where: { $0.name == "column_\(n)" }) { n += 1 }
        let c = DBColumn(name: "column_\(n)", type: dialect.typeHints.first { $0.lowercased().hasPrefix("varchar") || $0 == "TEXT" } ?? "text")
        d.columns.append(c)
        draft = d
        selectedField = c.id
    }

    func addIndex() {
        guard var d = draft, let first = d.columns.first else { return }
        let i = DBIndex(name: "\(d.name)_\(first.name)_idx", columns: [first.name], unique: false)
        d.indexes.append(i)
        draft = d
        selectedField = i.id
    }

    func addForeignKey() {
        guard var d = draft, let first = d.columns.first, let ref = ws?.objects.tables.first(where: { $0.name != d.name })?.name ?? ws?.objects.tables.first?.name else { return }
        let refPK = ws?.tableInfo[ref]?.primaryKey.first ?? "id"
        let f = DBForeignKey(name: "\(d.name)_\(first.name)_fk", columns: [first.name], refTable: ref, refColumns: [refPK])
        d.foreignKeys.append(f)
        draft = d
        selectedField = f.id
    }
}

/// A menu item with a closure
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, key: String = "", _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc func fire() { run() }
}
