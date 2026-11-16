import AppKit
import SwiftUI
import OpenAsyMacKit

/// Going to OpenAsy Schema: "Open in OpenAsy Schema" (it opens on its connection and schema import screen). The
/// connection record is shared, so only the id is passed; the password is in the shared keychain group, and Schema asks
/// for the file once.
@MainActor
enum SchemaApp {
    nonisolated static let scheme = "openasy-schema"

    /// Shown only when OpenAsy Schema is installed (whether an app can open the URL scheme)
    static var isInstalled: Bool { NSWorkspace.shared.urlForApplication(toOpen: URL(string: "\(scheme)://import")!) != nil }

    /// `openasy-schema://import?conn=<id>&schema=<name>`
    nonisolated static func importURL(conn: String, schema: String?) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "import"
        c.queryItems = [URLQueryItem(name: "conn", value: conn)]
        if let schema, !schema.isEmpty { c.queryItems?.append(URLQueryItem(name: "schema", value: schema)) }
        return c.url!
    }

    static func open(_ c: SavedConnection?, schema: String?) {
        guard let c else { return }
        NSWorkspace.shared.open(importURL(conn: c.id, schema: c.kind.isFile ? nil : schema))
    }

    /// The schema for the window's connection: the selected schema when connected, otherwise the connection's default
    static func schema(for c: SavedConnection, in ws: Workspace?) -> String {
        if let ws, ws.conn?.id == c.id, ws.isConnected { return ws.schema }
        return c.defaultSchema
    }
}

/// `openasy-database-client://` links from OpenAsy Schema (or anywhere else):
/// - `open?conn=<id>[&schema=<name>][&table=<name>]`: the connection's window (brought to the front if open), the
/// schema and table selected
/// - `query?conn=<id>[&schema=<name>](&file=<name>|&sql=<text>)`: a new query tab; the SQL comes from a file in the
/// group container's `inbox/` folder (deleted once read) or from the link. The query is not run.
@MainActor
final class LinkRouter {
    static let shared = LinkRouter()

    struct Link: Equatable {
        enum Kind: String { case open, query }
        var kind: Kind
        var conn: String
        var schema: String?
        var table: String?
        var file: String?
        var sql: String?
    }

    enum Action: Equatable {
        case schema(String)
        case table(schema: String?, name: String)
        case query(schema: String?, sql: String)
    }

    private final class Weak { weak var ws: Workspace?; init(_ ws: Workspace) { self.ws = ws } }
    private var workspaces: [Weak] = []
    private var pending: [String: [Action]] = [:]
    private var toOpen: [String] = []
    var openWindow: OpenWindowAction? { didSet { flush() } }

    nonisolated static func parse(_ url: URL) -> Link? {
        guard url.scheme?.lowercased() == "openasy-database-client", let kind = Link.Kind(rawValue: (url.host ?? "").lowercased()),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        guard let conn = q("conn") else { return nil }
        // The file name is taken as a name only (it cannot leave the folder)
        let file = q("file").map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty || $0.hasPrefix(".") ? nil : $0 }
        return Link(kind: kind, conn: conn, schema: q("schema"), table: q("table"), file: file, sql: q("sql"))
    }

    nonisolated static func action(_ l: Link, sql: String?) -> Action? {
        switch l.kind {
        case .open:
            if let t = l.table { return .table(schema: l.schema, name: t) }
            return l.schema.map { .schema($0) }
        case .query:
            return .query(schema: l.schema, sql: sql ?? l.sql ?? "")
        }
    }

    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let link = Self.parse(url) else { return false }
        let store = ConnectionStore.shared
        store.reload()
        guard store.connection(link.conn) != nil else {
            let a = NSAlert()
            a.messageText = L.t("link.noConnection")
            a.runModal()
            return true
        }
        if let a = Self.action(link, sql: link.file.flatMap(inbox)) { pending[link.conn, default: []].append(a) }
        if let ws = workspace(for: link.conn) {
            if ws.isConnected { Task { await apply(to: ws) } } else if ws.state != .connecting { Task { await ws.connect() } }
        }
        // The window comes to the front if open, otherwise it opens (pending work is applied once connected)
        toOpen.append(link.conn)
        flush()
        return true
    }

    /// An incoming SQL file in the group container (OpenAsy Schema writes it); deleted once read
    private func inbox(_ name: String) -> String? {
        guard let dir = OAMacAppGroup.containerURL(ConnectionStore.group) else { return nil }
        let f = dir.appendingPathComponent("inbox", isDirectory: true).appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: f) }
        return try? String(contentsOf: f, encoding: .utf8)
    }

    private func flush() {
        guard let openWindow, !toOpen.isEmpty else { return }
        let ids = toOpen
        toOpen = []
        for id in ids { openWindow(value: id) }
    }

    func register(_ ws: Workspace) {
        workspaces.removeAll { $0.ws == nil }
        workspaces.append(Weak(ws))
    }

    private func workspace(for id: String) -> Workspace? { workspaces.lazy.compactMap(\.ws).first { $0.conn?.id == id } }

    /// When the connection fails, pending work is dropped (so no unexpected tab opens on a later connection)
    func discard(_ id: String) { pending[id] = nil }

    /// Pending work once connected (or right away in an open window)
    func apply(to ws: Workspace) async {
        guard let id = ws.conn?.id, let actions = pending.removeValue(forKey: id) else { return }
        for a in actions {
            switch a {
            case .schema(let s):
                if ws.schemas.contains(s) { await ws.selectSchema(s) }
            case .table(let s, let name):
                if let s, ws.schemas.contains(s) { await ws.selectSchema(s) }
                ws.openTable(name)
            case .query(let s, let sql):
                if let s, ws.schemas.contains(s) { await ws.selectSchema(s) }
                ws.newQueryTab(sql: sql)
            }
        }
    }
}

