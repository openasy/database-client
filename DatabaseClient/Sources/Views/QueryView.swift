import AppKit
import SwiftUI
import OpenAsyMacKit

/// Editor colouring from the SQL tokenizer
@MainActor
func sqlHighlight(_ hash: Bool) -> (String) -> [OACodeToken] {
    { text in
        SQLLexer.tokenize(text, hashComments: hash).compactMap { tok, r in
            let s: OACodeToken.Style = switch tok {
            case .keyword: .keyword
            case .identifier: .identifier
            case .quoted: .quoted
            case .string: .string
            case .number: .number
            case .comment: .comment
            case .op: .op
            case .parameter: .parameter
            }
            return s == .identifier ? nil : OACodeToken(r, s)
        }
    }
}

struct QueryView: View {
    let ws: Workspace
    @Bindable var tab: QueryTab
    @Environment(\.oaMac) private var t

    var body: some View {
        VSplitView {
            OACodeView(text: $tab.sql, controller: tab.editor, fontSize: AppSettings.shared.editorFontSize, errorRange: tab.errorRange,
                       accessibilityLabel: L.t("query.editor"), highlight: sqlHighlight(ws.dialect.hashComments),
                       complete: { text, pos in tab.completions(text, pos) },
                       onCursor: { l, c in tab.cursor = (l, c) })
                .frame(minHeight: 120, idealHeight: 260)
            ResultsPane(ws: ws, tab: tab).frame(minHeight: 160)
        }
        .onAppear { tab.editor.focus() }
    }
}

struct ResultsPane: View {
    let ws: Workspace
    @Bindable var tab: QueryTab
    @Environment(\.oaMac) private var t
    @State private var gridVersion = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                OASegmented([(QueryTab.Pane.results, L.t("query.results")), (.plan, L.t("query.plan")), (.messages, L.t("query.messages"))], selection: $tab.pane)
                    .frame(width: 280)
                if tab.pane == .results, tab.results.count > 1 {
                    Picker("", selection: $tab.selectedResult) {
                        ForEach(Array(tab.results.enumerated()), id: \.offset) { i, r in Text(r.title).tag(i) }
                    }.labelsHidden().frame(width: 140)
                }
                if tab.running { ProgressView().controlSize(.small) }
                if let r = tab.current, tab.pane == .results {
                    Text(L.t("query.rows", ["n": r.result.rows.count, "ms": L.msNumber(r.result.ms)]) + (r.result.truncated ? " · " + L.t("query.truncated", ["n": AppSettings.shared.maxRows]) : ""))
                        .font(OAMacFont.sans(12)).foregroundStyle(t.text2).lineLimit(1)
                }
                Spacer()
                if let r = tab.current, tab.pane == .results {
                    Menu(L.t("export.title")) {
                        ForEach(Exporter.Format.allCases) { f in
                            Button(L.t("export.\(f.rawValue)")) { Exporter.save(r, rows: nil, format: f, name: L.t("query.exportName"), table: nil, dialect: ws.dialect, ws: ws) }
                        }
                        Divider()
                        Menu(L.t("share")) {
                            ForEach(Exporter.Format.allCases) { f in
                                Button(L.t("export.\(f.rawValue)")) { Exporter.share(r, format: f, name: L.t("query.exportName"), table: nil, dialect: ws.dialect) }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            .padding(.horizontal, 10).frame(height: 38)
            .background(t.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(t.border).frame(height: 1) }

            switch tab.pane {
            case .results:
                if let r = tab.current {
                    OADataGrid(source: r, version: r.version &+ gridVersion &+ tab.selectedResult * 1000, nullText: AppSettings.shared.nullText, accessibilityLabel: L.t("query.results"))
                        .onAppear { r.onSelection = { gridVersion += 0; ws.selectionTick += 1 } }
                } else {
                    OAEmptyState(icon: "play", title: L.t("query.emptyTitle"), text: L.t("query.empty")) {
                        Button(L.t("query.run") + "  ⌘↩") { tab.run(all: false) }.buttonStyle(.oaSecondary).disabled(!ws.isConnected)
                    }
                }
            case .plan:
                PlanView(tab: tab, ws: ws)
            case .messages:
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(tab.messages.reversed()) { m in
                            HStack(alignment: .top, spacing: 8) {
                                Text(m.date.formatted(date: .omitted, time: .standard)).font(OAMacFont.mono(11)).foregroundStyle(t.muted)
                                Text(m.text).font(OAMacFont.mono(12)).foregroundStyle(m.error ? t.danger : t.text).textSelection(.enabled)
                            }
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(t.panel2)
            }
        }
    }
}

struct PlanView: View {
    let tab: QueryTab
    let ws: Workspace
    @Environment(\.oaMac) private var t
    var body: some View {
        if tab.plan.isEmpty {
            OAEmptyState(icon: "plan", title: L.t("plan.emptyTitle"), text: L.t("plan.empty")) {
                Button(L.t("query.plan") + "  ⌥⌘E") { tab.explain() }.buttonStyle(.oaSecondary).disabled(!ws.isConnected)
                if ws.kind == .postgres || ws.kind == .mysql {
                    Button(L.t("plan.analyze")) { tab.explain(analyze: true) }.buttonStyle(.oaSecondary).disabled(!ws.isConnected)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(tab.planSQL).font(OAMacFont.mono(11.5)).foregroundStyle(t.text2).lineLimit(1)
                    Spacer()
                    if ws.kind == .postgres || ws.kind == .mysql { Button(L.t("plan.analyze")) { tab.explain(analyze: true) }.buttonStyle(.oa(.secondary, .small)) }
                }.padding(10)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(tab.plan) { PlanNodeView(node: $0, depth: 0) }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(t.panel2)
        }
    }
}

/// Plan node (an expanded tree; a full table scan in the warning colour)
struct PlanNodeView: View {
    let node: DBPlanNode
    let depth: Int
    @Environment(\.oaMac) private var t
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let scan = node.title.localizedCaseInsensitiveContains("seq scan") || node.estimate.contains("type=ALL") || node.title.localizedCaseInsensitiveContains("scan table")
            HStack(alignment: .firstTextBaseline) {
                Text(depth == 0 ? node.title : "↳ " + node.title).font(OAMacFont.sans(12.5, .medium)).foregroundStyle(scan ? t.warn : t.text)
                Spacer()
                Text(node.estimate).font(OAMacFont.mono(11)).foregroundStyle(t.muted).textSelection(.enabled)
            }
            ForEach(node.detail, id: \.self) { Text($0).font(OAMacFont.mono(11)).foregroundStyle(t.text2).padding(.leading, 18) }
            ForEach(node.children) { PlanNodeView(node: $0, depth: depth + 1) }.padding(.leading, 18)
        }
        .accessibilityElement(children: .contain)
    }
}

extension DBPlanNode {
    var childrenOrNil: [DBPlanNode]? { children.isEmpty ? nil : children }
}
