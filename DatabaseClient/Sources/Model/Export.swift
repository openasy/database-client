import AppKit
import UniformTypeIdentifiers
import OpenAsyMacKit

/// Export (CSV, JSON, SQL INSERT) and CSV import
enum Exporter {
    enum Format: String, CaseIterable, Identifiable {
        case csv, json, sql
        var id: String { rawValue }
        var ext: String { rawValue }
        var type: UTType { switch self { case .csv: .commaSeparatedText; case .json: .json; case .sql: UTType(filenameExtension: "sql") ?? .plainText } }
    }

    static func csvField(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    /// `rows`: the rows to export (all if empty)
    @MainActor
    static func render(_ src: OADataGridSource, rows: IndexSet?, format: Format, table: String?, dialect: (any SQLDialect)?, header: Bool = true) -> String {
        let cols = src.gridColumns.map(\.title)
        let idx = rows ?? IndexSet(0..<src.gridRowCount)
        func value(_ r: Int, _ c: Int) -> DBValue {
            let v = src.gridValue(row: r, column: c)
            return v.isNull ? .null : .text(v.text)
        }
        switch format {
        case .csv:
            var lines = header ? [cols.map(csvField).joined(separator: ",")] : []
            for r in idx { lines.append((0..<cols.count).map { c in value(r, c).text.map(csvField) ?? "" }.joined(separator: ",")) }
            return lines.joined(separator: "\r\n") + "\r\n"
        case .json:
            let arr: [[String: Any]] = idx.map { r in
                Dictionary(uniqueKeysWithValues: (0..<cols.count).map { c -> (String, Any) in
                    let v = value(r, c)
                    guard let t = v.text else { return (cols[c], NSNull()) }
                    if src.gridColumns[c].numeric, let n = Double(t), n.isFinite { return (cols[c], NSNumber(value: n)) }
                    return (cols[c], t)
                })
            }
            let d = (try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return String(decoding: d, as: UTF8.self) + "\n"
        case .sql:
            let d = dialect ?? PostgresDialect()
            let t = d.q(table ?? "result")
            let names = cols.map(d.q).joined(separator: ", ")
            return idx.map { r in
                "INSERT INTO \(t) (\(names)) VALUES (" + (0..<cols.count).map { d.literal(value(r, $0)) }.joined(separator: ", ") + ");"
            }.joined(separator: "\n") + "\n"
        }
    }

    @MainActor
    static func save(_ src: OADataGridSource, rows: IndexSet?, format: Format, name: String, table: String?, dialect: (any SQLDialect)?, ws: Workspace?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).\(format.ext)"
        panel.allowedContentTypes = [format.type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = render(src, rows: rows, format: format, table: table, dialect: dialect)
        do {
            try OAMacWrite.toUserFile(Data(text.utf8), url)
            ws?.toasts.show(L.t("saved", ["name": url.lastPathComponent]))
        } catch { ws?.toasts.show(L.t("err.save", ["msg": error.localizedDescription]), .error) }
    }

    @MainActor
    static func share(_ src: OADataGridSource, format: Format, name: String, table: String?, dialect: (any SQLDialect)?) {
        let text = render(src, rows: nil, format: format, table: table, dialect: dialect)
        OAMacShare.share(data: Data(text.utf8), fileName: "\(name).\(format.ext)", from: NSApp.keyWindow?.contentView)
    }

    // MARK: CSV import

    /// RFC 4180 CSV; the separator is detected (`,` `;` tab)
    static func parseCSV(_ text: String) -> [[String]] {
        let firstLine = text.prefix { $0 != "\n" }
        let sep: Character = [";", "\t", ","].max { a, b in firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count } ?? ","
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false
        var it = text.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? it.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let n = it.next() { if n == "\"" { field.append("\"") } else { quoted = false; pending = n } } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" { quoted = true } else if c == sep { row.append(field); field = "" } else if c == "\n" || c == "\r\n" {
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else if c == "\r" { continue } else { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

/// The grid's context menu: copy (TSV, CSV, JSON, INSERT), export
@MainActor
enum ExportMenu {
    static func make(source: OADataGridSource, rows: IndexSet, table: String? = nil, dialect: (any SQLDialect)? = nil) -> NSMenu? {
        let m = NSMenu()
        func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
        m.addItem(ClosureMenuItem(L.t("grid.copy")) { copy(oaGridTSV(source, rows: rows)) })
        m.addItem(ClosureMenuItem(L.t("grid.copyHeader")) { copy(oaGridTSV(source, rows: rows, header: true)) })
        m.addItem(ClosureMenuItem(L.t("grid.copyCSV")) { copy(Exporter.render(source, rows: rows, format: .csv, table: table, dialect: dialect)) })
        m.addItem(ClosureMenuItem(L.t("grid.copyJSON")) { copy(Exporter.render(source, rows: rows, format: .json, table: table, dialect: dialect)) })
        m.addItem(ClosureMenuItem(L.t("grid.copyInsert")) { copy(Exporter.render(source, rows: rows, format: .sql, table: table, dialect: dialect)) })
        return m
    }
}
