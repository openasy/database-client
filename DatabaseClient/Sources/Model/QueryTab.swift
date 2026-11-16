import AppKit
import SwiftUI
import OpenAsyMacKit

/// Texts: the app's single OAMacL10n
@MainActor
enum L {
    static let l10n = OAMacL10n(bundle: .main, directory: "i18n", forced: ProcessInfo.processInfo.environment["DBCLIENT_LANG"] ?? UserDefaults.standard.string(forKey: "lang"))
    static func t(_ k: String) -> String { l10n.t(k, [String: String]()) }
    static func t(_ k: String, _ v: [String: CustomStringConvertible]) -> String { l10n.t(k, v) }
    /// The texts write "{ms} ms": the number only
    static func msNumber(_ v: Double) -> String { v < 10 ? v.formatted(.number.precision(.fractionLength(1)).locale(l10n.locale)) : l10n.int(Int(v.rounded())) }
    static func err(_ e: Error) -> String {
        if let d = e as? DBError { return d.message }
        if let s = e as? OASSHError {
            switch s {
            case .unknownHost(let f): return t("ssh.unknown", ["f": f])
            case .hostKeyChanged(let a, let b): return t("ssh.changed", ["a": a, "b": b])
            case .unsupportedKey(let k): return t("ssh.unsupportedKey", ["k": k])
            case .badKey(let m): return t("ssh.badKey", ["msg": m])
            }
        }
        return (e as? LocalizedError)?.errorDescription ?? "\(e)"
    }
}

/// Query tab: editor, results (several), plan (EXPLAIN), messages
@MainActor @Observable
final class QueryTab: WorkTab {
    var sql: String
    var savedSQL: String
    var savedQueryID: String?
    var results: [ResultSource] = []
    var selectedResult = 0
    var plan: [DBPlanNode] = []
    var planSQL = ""
    var messages: [Message] = []
    var pane: Pane = .results
    var running = false
    var errorRange: NSRange?
    var cursor = (line: 1, col: 1)
    let editor = OACodeController()
    private var task: Task<Void, Never>?

    enum Pane: String { case results, plan, messages }
    struct Message: Identifiable, Hashable {
        let id = DBID.make()
        var text: String
        var error: Bool
        var date = Date()
    }

    init(ws: Workspace, title: String, sql: String) {
        self.sql = sql
        savedSQL = sql
        super.init(ws: ws, title: title)
    }
    override var icon: String { "code" }
    override var isDirty: Bool { sql != savedSQL && !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var current: ResultSource? { results.indices.contains(selectedResult) ? results[selectedResult] : nil }

    /// The selection or the statement under the cursor (⌘↩); `all`: every statement (⇧⌘↩)
    func statements(all: Bool) -> [(String, NSRange)] {
        let text = editor.text.isEmpty ? sql : editor.text
        let hash = ws?.dialect.hashComments ?? false
        let sel = editor.selectedRange
        if all { return SQLText.split(text, hashComments: hash).map { ($0.sql, $0.range) } }
        if sel.length > 0 {
            let part = (text as NSString).substring(with: sel)
            return SQLText.split(part, hashComments: hash).map { ($0.sql, NSRange(location: sel.location + $0.range.location, length: $0.range.length)) }
        }
        return SQLText.statement(at: sel.location, in: text, hashComments: hash).map { [($0.sql, $0.range)] } ?? []
    }

    func run(all: Bool) {
        guard let ws, ws.isConnected, !running else { return }
        let st = statements(all: all)
        guard !st.isEmpty else { return }
        ws.guardWrite(st.map(\.0)) { [weak self] in self?.start(st) }
    }

    private func start(_ st: [(String, NSRange)]) {
        guard let ws else { return }
        running = true
        errorRange = nil
        pane = .results
        task = Task {
            var out: [ResultSource] = []
            for (i, (s, range)) in st.enumerated() {
                do {
                    let r = try await ws.execute(s)
                    if r.isResultSet {
                        out.append(ResultSource(result: r, title: st.count > 1 ? L.t("query.resultN", ["n": i + 1]) : L.t("query.results")))
                        messages.append(Message(text: L.t("query.rows", ["n": r.rows.count, "ms": L.msNumber(r.ms)]) + (r.truncated ? " · " + L.t("query.truncated", ["n": AppSettings.shared.maxRows]) : ""), error: false))
                    } else {
                        messages.append(Message(text: L.t("query.affected", ["n": r.affected ?? 0, "ms": L.msNumber(r.ms)]), error: false))
                    }
                } catch {
                    let msg = L.err(error)
                    messages.append(Message(text: L.t("query.statementN", ["n": i + 1]) + ": " + msg, error: true))
                    if let pos = (error as? DBError)?.position, pos > 0 {
                        // Error position: a character in the statement to a UTF-16 range in the text (that word)
                        let local = String(s.prefix(pos - 1)).utf16.count
                        let ns = s as NSString
                        var end = local
                        while end < ns.length, let c = Unicode.Scalar(ns.character(at: end)), CharacterSet.alphanumerics.contains(c) || c == "_" { end += 1 }
                        errorRange = NSRange(location: range.location + local, length: max(1, end - local))
                    } else { errorRange = range }
                    if out.isEmpty { pane = .messages }
                    ws.toasts.show(msg, .error)
                    break
                }
                if Task.isCancelled { break }
            }
            if !out.isEmpty { results = out; selectedResult = 0 } else if pane != .messages { pane = .messages }
            running = false
            if st.contains(where: { SQLText.isWrite($0.0) }) { await ws.reloadObjects() }
        }
    }

    func stop() {
        guard running, let ws else { return }
        Task { await ws.session?.cancel() }
    }

    /// EXPLAIN (⌥⌘E): the plan of the statement under the cursor
    func explain(analyze: Bool = false) {
        guard let ws, ws.isConnected, let (s, _) = statements(all: false).first else { return }
        running = true
        Task {
            do {
                let r = try await ws.execute(DBExplain.sql(ws.dialect, s, analyze: analyze), record: false)
                plan = DBExplain.parse(ws.dialect, r)
                planSQL = s
                pane = .plan
            } catch {
                messages.append(Message(text: L.err(error), error: true))
                pane = .messages
                ws.toasts.show(L.err(error), .error)
            }
            running = false
        }
    }

    // MARK: Completion

    func completions(_ text: String, _ pos: Int) -> (items: [OACompletion], replace: NSRange) {
        guard AppSettings.shared.autocomplete, let ws else { return ([], NSRange()) }
        let w = SQLLexer.wordBefore(text, at: pos)
        let p = w.prefix.lowercased()
        var out: [OACompletion] = []
        if let q = w.qualifier?.lowercased() {
            let aliases = SQLLexer.aliases(text)
            let tname = aliases[q] ?? q
            if let t = ws.tableInfo[tname] ?? ws.tableInfo.first(where: { $0.key.lowercased() == tname.lowercased() })?.value {
                out = t.columns.filter { p.isEmpty || $0.name.lowercased().hasPrefix(p) }.map { OACompletion($0.name, detail: "\(t.name) · \($0.type)", kind: .column) }
            }
            return (out, w.range)
        }
        guard p.count >= 1 else { return ([], w.range) }
        let aliases = Set(SQLLexer.aliases(text).values.map { $0.lowercased() })
        for (name, t) in ws.tableInfo where aliases.contains(name.lowercased()) {
            out += t.columns.filter { $0.name.lowercased().hasPrefix(p) }.map { OACompletion($0.name, detail: "\(t.name) · \($0.type)", kind: .column) }
        }
        out += ws.objects.tables.filter { $0.name.lowercased().hasPrefix(p) }.map { OACompletion($0.name, detail: ws.schema, kind: .table) }
        out += ws.objects.views.filter { $0.name.lowercased().hasPrefix(p) }.map { OACompletion($0.name, detail: ws.schema, kind: .table) }
        out += SQLLexer.keywords.filter { $0.lowercased().hasPrefix(p) && $0.count > p.count }.sorted().map { OACompletion($0, kind: .keyword) }
        if out.count == 1, out[0].text.lowercased() == p { return ([], w.range) }
        return (out, w.range)
    }
}

/// Grid source for a query result (read-only; clicking a header sorts in memory)
@MainActor @Observable
final class ResultSource: OADataGridSource, Identifiable {
    let id = DBID.make()
    let result: DBResult
    let title: String
    @ObservationIgnored private var order: [Int]
    var sort: (column: Int, ascending: Bool)?
    var selectedRows = IndexSet()
    var selectedColumn: Int?
    @ObservationIgnored var onSelection: (() -> Void)?
    var version = 0
    @ObservationIgnored var requested: IndexSet?
    var gridRequestedSelection: IndexSet? { defer { requested = nil }; return requested }

    init(result: DBResult, title: String) {
        self.result = result
        self.title = title
        order = Array(result.rows.indices)
    }

    var gridColumns: [OAGridColumn] {
        result.columns.map { c in
            OAGridColumn(title: c.name, subtitle: c.type, numeric: ResultSource.isNumeric(c.type), width: ResultSource.width(c, result))
        }
    }
    var gridRowCount: Int { order.count }
    func row(_ r: Int) -> [DBValue] { result.rows[order[r]] }
    func gridValue(row r: Int, column c: Int) -> (text: String, isNull: Bool) {
        let v = result.rows[order[r]][c]
        return (v.display, v.isNull)
    }
    var gridSort: (column: Int, ascending: Bool)? { sort }
    func gridSortRequested(column: Int) {
        let asc = sort?.column == column ? !(sort!.ascending) : true
        sort = (column, asc)
        let num = ResultSource.isNumeric(result.columns[column].type)
        order.sort { a, b in
            let x = result.rows[a][column], y = result.rows[b][column]
            if x.isNull != y.isNull { return asc ? x.isNull : !x.isNull }
            let l: Bool
            if num, let dx = Double(x.display), let dy = Double(y.display) { l = dx < dy } else { l = x.display.localizedStandardCompare(y.display) == .orderedAscending }
            return asc ? l : !l
        }
        version += 1
        onSelection?()
    }
    func gridSelectionChanged(rows: IndexSet, column: Int?) {
        selectedRows = rows
        if let column { selectedColumn = column }
        onSelection?()
    }
    func gridMenu(rows: IndexSet, column: Int?) -> NSMenu? { ExportMenu.make(source: self, rows: rows) }

    static func isNumeric(_ t: String) -> Bool {
        let t = t.lowercased()
        return ["int", "numeric", "decimal", "float", "double", "real", "money", "serial", "bigint", "smallint", "tinyint", "mediumint", "year"].contains { t.hasPrefix($0) || t.contains($0) }
    }

    static func width(_ c: DBResultColumn, _ r: DBResult) -> CGFloat {
        let sample = r.rows.prefix(50).map { $0.isEmpty ? 0 : 0 }
        _ = sample
        let idx = r.columns.firstIndex(of: c) ?? 0
        let longest = r.rows.prefix(80).map { min(60, $0[idx].display.count) }.max() ?? 4
        return min(420, max(70, CGFloat(max(longest, c.name.count + c.type.count / 2 + 2)) * 7.6 + 18))
    }
}
