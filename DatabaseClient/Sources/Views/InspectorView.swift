import AppKit
import SwiftUI
import OpenAsyMacKit

struct InspectorView: View {
    let ws: Workspace
    @Environment(\.oaMac) private var t
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let _ = ws.selectionTick
                switch ws.selected {
                case let q as QueryTab: QueryInspector(ws: ws, tab: q)
                case let tt as TableTab where tt.mode == .data: RowInspector(tab: tt)
                case let tt as TableTab where tt.mode == .structure: StructureInspector(ws: ws, tab: tt)
                default: ConnectionInspector(ws: ws)
                }
            }
        }
        .background(t.panel)
    }
}

/// Cell viewer (a JSON tree or text) and the row's values
struct QueryInspector: View {
    let ws: Workspace
    let tab: QueryTab
    @State private var asTree = true
    @Environment(\.oaMac) private var t
    var body: some View {
        if let r = tab.current, let row = r.selectedRows.first, row < r.gridRowCount {
            let values = r.row(row)
            let col = r.selectedColumn ?? 0
            let c = r.result.columns[col]
            let v = values[col]
            OAInspectorSection(L.t("inspector.cell", ["name": c.name])) {
                OAKeyValue(L.t("inspector.type"), c.type.isEmpty ? "–" : c.type)
                OAKeyValue(L.t("inspector.row"), "\(row + 1)")
                let json = v.text.flatMap(JSONNode.parse)
                if json != nil {
                    OASegmented([(true, L.t("inspector.tree")), (false, L.t("inspector.text"))], selection: $asTree)
                }
                Group {
                    if let json, asTree {
                        JSONTreeView(node: json)
                    } else {
                        Text(prettyJSON(v.text) ?? (v.isNull ? AppSettings.shared.nullText : v.text ?? ""))
                            .font(OAMacFont.mono(12)).foregroundStyle(v.isNull ? t.muted : t.text).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10).background(t.panel2, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(t.border))
                Button(L.t("kit_copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(v.text ?? "", forType: .string) }.buttonStyle(.oa(.secondary, .small))
            }
            OAInspectorSection(L.t("inspector.rowTitle")) {
                ForEach(Array(r.result.columns.enumerated()), id: \.offset) { i, c in OAKeyValue(c.name, values[i].display) }
            }
        } else {
            OAInspectorSection(L.t("inspector.cellEmpty")) {
                Text(L.t("inspector.cellHint")).font(OAMacFont.sans(12)).foregroundStyle(t.text2)
            }
        }
    }
}

/// Row editor (Data): fields write to the pending change
struct RowInspector: View {
    @Bindable var tab: TableTab
    @Environment(\.oaMac) private var t
    var body: some View {
        if let row = tab.selectedRows.first, row < tab.gridRowCount {
            let key = row < tab.rows.count ? tab.key(for: row) : nil
            OAInspectorSection(row < tab.rows.count ? L.t("inspector.rowKey", ["key": key.map { zip($0.columns, $0.values).map { "\($0) \($1.display)" }.joined(separator: ", ") } ?? ""]) : L.t("inspector.newRow")) {
                ForEach(Array(tab.columns.enumerated()), id: \.offset) { i, c in
                    let v = tab.gridValue(row: row, column: i)
                    OAFormRow(c.name, width: 96) {
                        HStack(spacing: 4) {
                            TextField(v.isNull ? v.text : "", text: Binding(get: { v.isNull ? "" : v.text }, set: { tab.setValue(.text($0), row: row, column: i) }))
                                .textFieldStyle(.oaMono).disabled(!tab.gridCanEdit(row: row, column: i))
                            Button("∅") { tab.setValue(.null, row: row, column: i) }.buttonStyle(.oa(.plain, .small)).help(L.t("data.setNull"))
                                .accessibilityLabel(L.t("data.setNull") + " " + c.name).disabled(!tab.gridCanEdit(row: row, column: i))
                        }
                    }
                }
                Text(L.t("data.hint")).font(OAMacFont.sans(11.5)).foregroundStyle(t.text2).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            OAInspectorSection(L.t("inspector.rowTitle")) {
                Text(L.t("data.hint")).font(OAMacFont.sans(12)).foregroundStyle(t.text2).fixedSize(horizontal: false, vertical: true)
                if tab.info?.primaryKey.isEmpty == true {
                    OANotice(.warn, tab.usesRowIdentity ? L.t("data.noPkRowid") : L.t("data.noPk"))
                }
            }
        }
    }
}

/// Structure inspector: the selected column, index or foreign key
struct StructureInspector: View {
    let ws: Workspace
    @Bindable var tab: TableTab
    @Environment(\.oaMac) private var t

    var body: some View {
        if var d = tab.draft {
            let id = tab.selectedField
            if let i = d.columns.firstIndex(where: { $0.id == id }) {
                OAInspectorSection(L.t("structure.column", ["name": d.columns[i].name])) {
                    OAFormRow(L.t("te.colName"), width: 90) { TextField("", text: bind(&d, \.columns[i].name)).textFieldStyle(.oaMono) }
                    OAFormRow(L.t("te.colType"), width: 90) {
                        HStack(spacing: 4) {
                            TextField("", text: bind(&d, \.columns[i].type)).textFieldStyle(.oaMono)
                            Menu("") { ForEach(ws.dialect.typeHints, id: \.self) { h in Button(h) { var x = tab.draft!; x.columns[i].type = h; tab.draft = x } } }
                                .menuStyle(.borderlessButton).frame(width: 22).accessibilityLabel(L.t("te.colType"))
                        }
                    }
                    OAFormRow(L.t("te.default"), width: 90) {
                        TextField("NULL", text: Binding(get: { tab.draft?.columns[i].default ?? "" }, set: { var x = tab.draft!; x.columns[i].default = $0.isEmpty ? nil : $0; tab.draft = x })).textFieldStyle(.oaMono)
                    }
                    Toggle(L.t("te.nnLong"), isOn: Binding(get: { !(tab.draft?.columns[i].nullable ?? true) }, set: { var x = tab.draft!; x.columns[i].nullable = !$0; tab.draft = x }))
                    Toggle(L.t("te.pkLong"), isOn: Binding(get: { tab.draft?.primaryKey.contains(d.columns[i].name) ?? false }, set: { on in
                        var x = tab.draft!; let n = x.columns[i].name
                        if on { if !x.primaryKey.contains(n) { x.primaryKey.append(n) } } else { x.primaryKey.removeAll { $0 == n } }
                        tab.draft = x
                    }))
                    Toggle(L.t("te.aiLong"), isOn: Binding(get: { tab.draft?.columns[i].autoInc ?? false }, set: { var x = tab.draft!; x.columns[i].autoInc = $0; tab.draft = x }))
                    if ws.kind != .sqlite {
                        OAFormRow(L.t("te.comment"), width: 90) {
                            TextField("", text: Binding(get: { tab.draft?.columns[i].comment ?? "" }, set: { var x = tab.draft!; x.columns[i].comment = $0.isEmpty ? nil : $0; tab.draft = x })).textFieldStyle(.oa)
                        }
                    }
                    HStack {
                        Button(L.t("structure.up")) { move(i, -1) }.buttonStyle(.oa(.secondary, .small)).disabled(i == 0 || ws.kind != .mysql && ws.kind != .mariadb && tab.info?.columns.contains { $0.id == d.columns[i].id } == true)
                        Spacer()
                        Button(L.t("te.delCol", ["name": d.columns[i].name])) { var x = tab.draft!; let n = x.columns[i].name; x.columns.remove(at: i); x.primaryKey.removeAll { $0 == n }; tab.draft = x; tab.selectedField = nil }
                            .buttonStyle(.oa(.danger, .small))
                    }
                    OANotice(.info, L.t("structure.note"))
                }
            } else if let i = d.indexes.firstIndex(where: { $0.id == id }) {
                OAInspectorSection(L.t("structure.index", ["name": d.indexes[i].name])) {
                    OAFormRow(L.t("te.idxName"), width: 90) { TextField("", text: bind(&d, \.indexes[i].name)).textFieldStyle(.oaMono) }
                    OAFormRow(L.t("te.fkCols"), width: 90) { columnsPicker(Binding(get: { tab.draft!.indexes[i].columns }, set: { var x = tab.draft!; x.indexes[i].columns = $0; tab.draft = x })) }
                    Toggle(L.t("te.uqLong"), isOn: Binding(get: { tab.draft?.indexes[i].unique ?? false }, set: { var x = tab.draft!; x.indexes[i].unique = $0; tab.draft = x }))
                    Button(L.t("te.delIdx", ["name": d.indexes[i].name])) { var x = tab.draft!; x.indexes.remove(at: i); tab.draft = x; tab.selectedField = nil }.buttonStyle(.oa(.danger, .small))
                }
            } else if let i = d.foreignKeys.firstIndex(where: { $0.id == id }) {
                OAInspectorSection(L.t("structure.fk", ["name": d.foreignKeys[i].name])) {
                    OAFormRow(L.t("te.fkName"), width: 90) { TextField("", text: bind(&d, \.foreignKeys[i].name)).textFieldStyle(.oaMono) }
                    OAFormRow(L.t("te.fkCols"), width: 90) { columnsPicker(Binding(get: { tab.draft!.foreignKeys[i].columns }, set: { var x = tab.draft!; x.foreignKeys[i].columns = $0; tab.draft = x })) }
                    OAFormRow(L.t("te.refTable"), width: 90) {
                        Picker("", selection: Binding(get: { tab.draft!.foreignKeys[i].refTable }, set: { v in
                            var x = tab.draft!; x.foreignKeys[i].refTable = v; x.foreignKeys[i].refColumns = [ws.tableInfo[v]?.primaryKey.first ?? "id"]; tab.draft = x
                        })) { ForEach(ws.objects.tables) { Text($0.name).tag($0.name) } }.labelsHidden()
                    }
                    OAFormRow(L.t("te.refCols"), width: 90) {
                        TextField("", text: Binding(get: { tab.draft!.foreignKeys[i].refColumns.joined(separator: ", ") }, set: { var x = tab.draft!; x.foreignKeys[i].refColumns = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }; tab.draft = x })).textFieldStyle(.oaMono)
                    }
                    OAFormRow("ON DELETE", width: 90) { actionPicker(\.onDelete, i) }
                    OAFormRow("ON UPDATE", width: 90) { actionPicker(\.onUpdate, i) }
                    Button(L.t("te.delFk", ["name": d.foreignKeys[i].name])) { var x = tab.draft!; x.foreignKeys.remove(at: i); tab.draft = x; tab.selectedField = nil }.buttonStyle(.oa(.danger, .small))
                }
            } else {
                OAInspectorSection(L.t("te.table")) {
                    OAFormRow(L.t("te.name"), width: 90) { TextField("", text: bind(&d, \.name)).textFieldStyle(.oaMono) }
                    if ws.kind != .sqlite {
                        OAFormRow(L.t("te.comment"), width: 90) {
                            TextField("", text: Binding(get: { tab.draft?.comment ?? "" }, set: { var x = tab.draft!; x.comment = $0.isEmpty ? nil : $0; tab.draft = x })).textFieldStyle(.oa)
                        }
                    }
                    Text(L.t("structure.pick")).font(OAMacFont.sans(12)).foregroundStyle(t.text2)
                }
            }
        }
    }

    func bind(_ d: inout DBTable, _ kp: WritableKeyPath<DBTable, String>) -> Binding<String> {
        Binding(get: { tab.draft?[keyPath: kp] ?? "" }, set: { var x = tab.draft!; x[keyPath: kp] = $0; tab.draft = x })
    }

    func move(_ i: Int, _ d: Int) {
        guard var x = tab.draft, i + d >= 0, i + d < x.columns.count else { return }
        x.columns.swapAt(i, i + d)
        tab.draft = x
    }

    func columnsPicker(_ b: Binding<[String]>) -> some View {
        Menu(b.wrappedValue.isEmpty ? "–" : b.wrappedValue.joined(separator: ", ")) {
            ForEach(tab.draft?.columns ?? []) { c in
                Toggle(c.name, isOn: Binding(get: { b.wrappedValue.contains(c.name) }, set: { on in
                    if on { b.wrappedValue.append(c.name) } else { b.wrappedValue.removeAll { $0 == c.name } }
                }))
            }
        }
        .accessibilityLabel(L.t("te.fkCols"))
    }

    func actionPicker(_ kp: WritableKeyPath<DBForeignKey, DBFkAction>, _ i: Int) -> some View {
        Picker("", selection: Binding(get: { tab.draft!.foreignKeys[i][keyPath: kp] }, set: { var x = tab.draft!; x.foreignKeys[i][keyPath: kp] = $0; tab.draft = x })) {
            ForEach(DBFkAction.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.labelsHidden()
    }
}

struct ConnectionInspector: View {
    let ws: Workspace
    var body: some View {
        if let c = ws.conn {
            OAInspectorSection(L.t("query.connection")) {
                OAKeyValue(L.t("conn.kind"), c.kind.displayName + (ws.session.map { " " + $0.serverVersion } ?? ""), mono: false)
                if !c.kind.isFile {
                    OAKeyValue(L.t("conn.host"), "\(c.host):\(c.port)")
                    OAKeyValue(L.t("conn.user"), c.user)
                    if c.sshEnabled { OAKeyValue("SSH", "\(c.sshUser)@\(c.sshHost)") }
                    if let f = ws.session?.sshFingerprint { OAKeyValue(L.t("ssh.fingerprint"), f) }
                    OAKeyValue("TLS", L.t("conn.tls.\(c.tls.rawValue)"), mono: false)
                } else { OAKeyValue(L.t("conn.file"), c.filePath ?? "") }
                OAKeyValue(L.t("schema.pick"), ws.schema)
                OAKeyValue(L.t("schema.tablesShort"), "\(ws.objects.tables.count)")
            }
        }
    }
}

/// JSON tree (cell viewer)
struct JSONNode: Identifiable, Hashable {
    let id = DBID.make()
    var key: String
    var value: String
    var children: [JSONNode]?

    static func parse(_ s: String) -> JSONNode? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["), let d = trimmed.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) else { return nil }
        return make("", o)
    }

    static func make(_ k: String, _ o: Any) -> JSONNode {
        if let d = o as? [String: Any] { return JSONNode(key: k, value: "{\(d.count)}", children: d.keys.sorted().map { make($0, d[$0]!) }) }
        if let a = o as? [Any] { return JSONNode(key: k, value: "[\(a.count)]", children: a.enumerated().map { make("\($0.offset)", $0.element) }) }
        if o is NSNull { return JSONNode(key: k, value: "null") }
        if let s = o as? String { return JSONNode(key: k, value: "\"\(s)\"") }
        if let n = o as? NSNumber { return JSONNode(key: k, value: CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue) }
        return JSONNode(key: k, value: "\(o)")
    }
}

/// Turns JSON into indented text; nil if it is not JSON
func prettyJSON(_ s: String?) -> String? {
    guard let s, let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]),
          o is [Any] || o is [String: Any],
          let out = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
    return String(decoding: out, as: UTF8.self)
}

struct JSONTreeView: View {
    let node: JSONNode
    @Environment(\.oaMac) private var t
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            OutlineGroup(node.children ?? [node], children: \.children) { n in
                HStack(spacing: 6) {
                    Text(n.key).font(OAMacFont.mono(12)).foregroundStyle(t.accentText)
                    Text(n.value).font(OAMacFont.mono(12)).foregroundStyle(n.value.hasPrefix("\"") ? t.warn : t.text).lineLimit(3).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
