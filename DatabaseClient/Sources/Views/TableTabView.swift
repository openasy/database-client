import AppKit
import SwiftUI
import OpenAsyMacKit

struct TableTabView: View {
    let ws: Workspace
    @Bindable var tab: TableTab
    @Environment(\.oaMac) private var t

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                OASegmented(modes, selection: $tab.mode).frame(width: 340)
                Text("\(tab.schema).\(tab.table)").font(OAMacFont.mono(12)).foregroundStyle(t.text2).lineLimit(1)
                Spacer()
                switch tab.mode {
                case .data:
                    if tab.editable {
                        Button { tab.addRow() } label: { Label(L.t("data.addRow"), systemImage: "plus") }.buttonStyle(.oa(.secondary, .small)).help(L.t("data.addRow") + " (⌥⌘N)")
                        Button { tab.deleteRows(tab.selectedRows) } label: { Label(L.t("data.delete"), systemImage: "trash") }.buttonStyle(.oa(.secondary, .small))
                            .disabled(tab.selectedRows.isEmpty).help(L.t("data.delete") + " (⌘⌫)")
                    }
                    Button { tab.requery() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.oa(.secondary, .small)).help(L.t("data.reload")).accessibilityLabel(L.t("data.reload"))
                case .structure:
                    if !tab.isView, ws.conn?.readOnly != true {
                        Button { tab.addColumn() } label: { Label(L.t("te.addCol"), systemImage: "plus") }.buttonStyle(.oa(.secondary, .small))
                        if ws.kind != .redshift { Button(L.t("te.addIdx")) { tab.addIndex() }.buttonStyle(.oa(.secondary, .small)) }
                        Button(L.t("te.addFk")) { tab.addForeignKey() }.buttonStyle(.oa(.secondary, .small))
                    }
                case .ddl:
                    Button(L.t("ddl.openInQuery")) { ws.newQueryTab(sql: tab.ddl) }.buttonStyle(.oa(.secondary, .small))
                }
            }
            .padding(.horizontal, 10).frame(height: 40)
            .background(t.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(t.border).frame(height: 1) }

            if let e = tab.loadError { OANotice(.error, e).padding(10) }

            switch tab.mode {
            case .data: DataPane(ws: ws, tab: tab)
            case .structure: StructurePane(ws: ws, tab: tab)
            case .ddl:
                ScrollView([.vertical, .horizontal]) {
                    Text(tab.ddl).font(OAMacFont.mono(12.5)).foregroundStyle(t.text).textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }.background(t.panel2)
            }
        }
        .sheet(isPresented: $tab.showPreview) {
            SQLPreviewSheet(title: L.t("data.previewTitle"), subtitle: L.t("data.previewLead", ["n": tab.pendingSQL.count]), sql: tab.pendingSQL,
                            note: ws.inTransaction ? L.t("data.inTx") : nil, action: L.t("data.commit"), busy: tab.committing,
                            onCancel: { tab.showPreview = false }, onRun: { tab.commit() })
        }
        .sheet(isPresented: $tab.showStructurePreview) {
            SQLPreviewSheet(title: L.t("structure.previewTitle"), subtitle: tab.structureDetails.joined(separator: " · "), sql: tab.structureSQL,
                            note: ws.dialect.transactionalDDL ? nil : L.t("sync.mysqlNote"), action: L.t("structure.apply"), busy: false,
                            onCancel: { tab.showStructurePreview = false }, onRun: { tab.applyStructure() })
        }
    }

    var modes: [(TableTab.Mode, String)] {
        tab.isView ? [(.data, L.t("table.data")), (.ddl, L.t("table.createSQL"))] : [(.data, L.t("table.data")), (.structure, L.t("table.structure")), (.ddl, L.t("table.createSQL"))]
    }
}

struct DataPane: View {
    let ws: Workspace
    @Bindable var tab: TableTab
    @Environment(\.oaMac) private var t

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(tab: tab)
            ZStack(alignment: .bottom) {
                OADataGrid(source: tab, version: tab.version, nullText: AppSettings.shared.nullText, accessibilityLabel: L.t("table.data") + " " + tab.table)
                if tab.loading || !tab.exhausted {
                    HStack(spacing: 6) {
                        if tab.loading { ProgressView().controlSize(.mini) } else { Circle().fill(t.warn).frame(width: 7, height: 7) }
                        Text(L.t("data.loadedMore", ["n": tab.rows.count, "total": tab.total.map { L.l10n.int64($0) } ?? "?", "page": AppSettings.shared.pageSize]))
                    }
                    .font(OAMacFont.sans(11.5)).foregroundStyle(t.text2)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(t.panel, in: Capsule()).padding(.bottom, 8)
                }
            }
            if tab.hasDataChanges { PendingBar(ws: ws, tab: tab) }
        }
    }
}

struct FilterBar: View {
    @Bindable var tab: TableTab
    @Environment(\.oaMac) private var t
    var body: some View {
        HStack(spacing: 8) {
            ForEach($tab.filters) { $f in
                HStack(spacing: 0) {
                    Picker("", selection: $f.column) { ForEach(tab.columns, id: \.name) { Text($0.name).tag($0.name) } }
                        .labelsHidden().frame(width: 120).accessibilityLabel(L.t("filter.column"))
                    Picker("", selection: $f.op) { ForEach(DBFilter.Op.allCases, id: \.self) { Text($0.symbol).tag($0) } }
                        .labelsHidden().frame(width: 74).accessibilityLabel(L.t("filter.op"))
                    if f.op.needsValue {
                        TextField(L.t("filter.value"), text: $f.value).textFieldStyle(.oaMono).frame(width: 130).onSubmit { tab.requery() }
                    }
                    Button { tab.filters.removeAll { $0.id == f.id }; tab.requery() } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                        .buttonStyle(.plain).foregroundStyle(t.muted).padding(.horizontal, 6).accessibilityLabel(L.t("filter.remove"))
                }
            }
            Button { tab.filters.append(DBFilter(column: tab.columns.first?.name ?? "")) } label: { Label(L.t("filter.add"), systemImage: "plus") }
                .buttonStyle(.oa(.plain, .small)).disabled(tab.columns.isEmpty)
            if !tab.filters.isEmpty {
                Button(L.t("filter.apply")) { tab.requery() }.buttonStyle(.oa(.secondary, .small)).keyboardShortcut(.return, modifiers: [.command, .shift])
                Button(L.t("filter.clear")) { tab.filters = []; tab.requery() }.buttonStyle(.oa(.plain, .small))
            }
            Spacer()
            if let w = tab.dialect.filterSQL(tab.filters) { Text("WHERE " + w).font(OAMacFont.mono(11)).foregroundStyle(t.muted).lineLimit(1).truncationMode(.head) }
        }
        .padding(.horizontal, 10).frame(minHeight: 36)
        .background(t.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(t.border).frame(height: 1) }
    }
}

struct PendingBar: View {
    let ws: Workspace
    @Bindable var tab: TableTab
    @Environment(\.oaMac) private var t
    var body: some View {
        let c = tab.counts
        HStack(spacing: 8) {
            Image(systemName: "pencil").foregroundStyle(t.accentText)
            Text(L.t("data.pending")).font(OAMacFont.sans(12.5, .semibold)).foregroundStyle(t.text)
            if c.edit > 0 { chip(L.t("data.nEdits", ["n": c.edit]), t.warn) }
            if c.insert > 0 { chip(L.t("data.nInserts", ["n": c.insert]), t.ok) }
            if c.delete > 0 { chip(L.t("data.nDeletes", ["n": c.delete]), t.danger) }
            Spacer()
            Button(L.t("data.showSQL")) { tab.showPreview = true }.buttonStyle(.oa(.plain, .small))
            Button(L.t("data.discard")) { tab.discard() }.buttonStyle(.oa(.secondary, .small)).keyboardShortcut(.escape, modifiers: [.command])
            Button(L.t("data.commit") + "  ⌘S") { tab.commit() }.buttonStyle(.oa(.primary, .small)).disabled(tab.committing)
        }
        .padding(.horizontal, 12).frame(height: 44)
        .background(t.accentBg)
        .overlay(alignment: .top) { Rectangle().fill(t.accentLine).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
    func chip(_ s: String, _ c: Color) -> some View {
        Text(s).font(OAMacFont.sans(11.5, .medium)).foregroundStyle(t.text).padding(.horizontal, 8).padding(.vertical, 2).background(c.opacity(0.22), in: Capsule())
    }
}

/// SQL preview: the statements to apply, copy, open in a query tab, run
struct SQLPreviewSheet: View {
    let title: String
    let subtitle: String
    let sql: [String]
    let note: String?
    let action: String
    let busy: Bool
    let onCancel: () -> Void
    let onRun: () -> Void
    @Environment(\.oaMac) private var t
    var body: some View {
        OASheet(title, subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView([.vertical, .horizontal]) {
                    Text(scriptText(sql)).font(OAMacFont.mono(12)).foregroundStyle(t.text).textSelection(.enabled).padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 220, maxHeight: 420)
                .background(t.panel2, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(t.border))
                if let note { OANotice(.warn, note) }
            }
        } footer: {
            Button(L.t("kit_copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(scriptText(sql), forType: .string) }.buttonStyle(.oaSecondary)
            Spacer()
            Button(L.t("cancel"), action: onCancel).buttonStyle(.oaSecondary).keyboardShortcut(.cancelAction)
            Button(action, action: onRun).buttonStyle(.oaPrimary).keyboardShortcut(.defaultAction).disabled(busy || sql.isEmpty)
        }
        .frame(width: 720)
    }
}

/// Structure: columns, indexes, foreign keys; the selected item is edited in the inspector
struct StructurePane: View {
    let ws: Workspace
    @Bindable var tab: TableTab
    @Environment(\.oaMac) private var t

    var body: some View {
        VStack(spacing: 0) {
            if let d = tab.draft {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        section(L.t("te.columns", ["n": d.columns.count])) {
                            grid(header: [L.t("te.colName"), L.t("te.colType"), L.t("key.null"), L.t("te.default"), L.t("structure.key"), L.t("te.comment")], rows: d.columns.map { c in
                                (c.id, [c.name, c.type, c.nullable ? L.t("yes") : L.t("no"), c.default ?? "NULL",
                                        d.primaryKey.contains(c.name) ? "PK" : (d.foreignKeys.contains { $0.columns.contains(c.name) } ? "FK" : ""), c.comment ?? ""],
                                 tab.info?.columns.first { $0.id == c.id } != c)
                            })
                        }
                        HStack(alignment: .top, spacing: 16) {
                            if ws.kind != .redshift {
                                section(L.t("te.indexes", ["n": d.indexes.count])) {
                                    grid(header: [L.t("te.idxName"), L.t("te.fkCols"), L.t("structure.idxKind")], rows: d.indexes.map { i in
                                        (i.id, [i.name, i.columns.joined(separator: ", "), i.unique ? "UNIQUE" : "INDEX"], tab.info?.indexes.first { $0.id == i.id } != i)
                                    })
                                }
                            }
                            section(L.t("te.fks", ["n": d.foreignKeys.count])) {
                                grid(header: [L.t("te.fkName"), L.t("te.fkCols"), L.t("te.refTable"), "ON DELETE"], rows: d.foreignKeys.map { f in
                                    (f.id, [f.name, f.columns.joined(separator: ", "), "\(f.refTable)(\(f.refColumns.joined(separator: ", ")))", f.onDelete.rawValue], tab.info?.foreignKeys.first { $0.id == f.id } != f)
                                })
                            }
                        }
                    }
                    .padding(14)
                }
                if tab.hasStructureChanges {
                    HStack(spacing: 8) {
                        Image(systemName: "pencil").foregroundStyle(t.accentText)
                        Text(L.t("structure.pending")).font(OAMacFont.sans(12.5, .semibold))
                        ForEach(tab.structureDetails.prefix(3), id: \.self) { s in
                            Text(s).font(OAMacFont.sans(11.5)).padding(.horizontal, 8).padding(.vertical, 2).background(t.warn.opacity(0.2), in: Capsule()).lineLimit(1)
                        }
                        Spacer()
                        Button(L.t("data.discard")) { tab.discardStructure() }.buttonStyle(.oa(.secondary, .small))
                        Button(L.t("structure.preview")) { tab.showStructurePreview = true }.buttonStyle(.oa(.primary, .small))
                    }
                    .padding(.horizontal, 12).frame(height: 44)
                    .background(t.accentBg)
                    .overlay(alignment: .top) { Rectangle().fill(t.accentLine).frame(height: 1) }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(t.bg)
    }

    func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(OAMacFont.sans(12.5, .semibold)).foregroundStyle(t.text2).accessibilityAddTraits(.isHeader)
            c()
        }
    }

    func grid(header: [String], rows: [(String, [String], Bool)]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(header.enumerated()), id: \.offset) { _, h in
                    Text(h).font(OAMacFont.sans(11.5, .semibold)).foregroundStyle(t.text2).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                }
            }.frame(height: 26).background(t.panel)
            ForEach(rows, id: \.0) { id, cells, changed in
                let on = tab.selectedField == id
                HStack(spacing: 0) {
                    ForEach(Array(cells.enumerated()), id: \.offset) { i, c in
                        Text(c).font(i == 0 || i == 1 ? OAMacFont.mono(12) : OAMacFont.sans(12)).foregroundStyle(c == "NULL" ? t.muted : t.text)
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                    }
                }
                .frame(height: 26)
                .background(on ? t.accentBg : changed ? t.warnBg : .clear)
                .overlay(alignment: .bottom) { Rectangle().fill(t.border).frame(height: 1) }
                .contentShape(Rectangle())
                .onTapGesture { tab.selectedField = id; ws.showInspector = true }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { tab.selectedField = id; ws.showInspector = true }
            }
        }
        .background(t.panel2, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(t.border))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
