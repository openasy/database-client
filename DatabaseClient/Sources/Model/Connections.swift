import AppKit
import Foundation
import OSLog
import OpenAsyMacKit

/// A saved connection. The record is shared with OpenAsy Schema (connections.json in the app group, `OADBConnection`);
/// passwords are in the keychain's shared group (`com.openasy.db`, `conn:<id>:db` and `conn:<id>:ssh`). Files (SQLite,
/// SSH key, CA) are kept as security-scoped bookmarks; bookmarks belong to the app and stay in its own container.
struct SavedConnection: Codable, Identifiable, Hashable {
    typealias Tag = OADBConnection.Tag
    typealias SSHAuth = OADBConnection.SSHAuth

    var id: String = DBID.make()
    var name: String = ""
    var kind: DBKind = .postgres
    var host: String = "localhost"
    var port: Int = 5432
    var user: String = ""
    var database: String = ""
    var defaultSchema: String = ""
    var tag: Tag = .none
    var readOnly = false
    var savePassword = true
    var tls: OATLSConfig.Mode = .off
    var caBookmark: Data?
    var caName: String?
    var clientCertBookmark: Data?
    var clientKeyBookmark: Data?
    var clientCertName: String?

    var sshEnabled = false
    var sshHost: String = ""
    var sshPort: Int = 22
    var sshUser: String = ""
    var sshAuth: SSHAuth = .key
    var sshKeyBookmark: Data?
    var sshKeyName: String?

    /// SQLite file
    var fileBookmark: Data?
    var filePath: String?

    var lastUsed: Date?
    /// Fields in the shared record this version does not know (from OpenAsy Schema or a newer version): written back as
    /// they were
    var extra: [String: OAJSON]?

    var displayName: String { name.isEmpty ? (kind.isFile ? (filePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "SQLite") : host) : name }

    var dbAccount: String { OADBConnection.dbAccount(id) }
    var sshAccount: String { OADBConnection.sshAccount(id) }
}

extension SavedConnection {
    typealias Slot = OADBConnectionBookmarks.Slot

    init(_ r: OADBConnection, bookmarks b: [Slot: Data]) {
        id = r.id; name = r.name; kind = r.kind; host = r.host; port = r.port; user = r.user; database = r.database
        defaultSchema = r.defaultSchema; tag = r.tag; readOnly = r.readOnly; savePassword = r.savePassword; tls = r.tls
        caName = r.caName; clientCertName = r.clientCertName
        sshEnabled = r.sshEnabled; sshHost = r.sshHost; sshPort = r.sshPort; sshUser = r.sshUser; sshAuth = r.sshAuth
        sshKeyName = r.sshKeyName; filePath = r.filePath; lastUsed = r.lastUsed; extra = r.extra.isEmpty ? nil : r.extra
        fileBookmark = b[.file]; sshKeyBookmark = b[.sshKey]; caBookmark = b[.ca]; clientCertBookmark = b[.clientCert]; clientKeyBookmark = b[.clientKey]
    }

    /// The shared record (without bookmarks)
    var record: OADBConnection {
        var r = OADBConnection()
        r.id = id; r.name = name; r.kind = kind; r.host = host; r.port = port; r.user = user; r.database = database
        r.defaultSchema = defaultSchema; r.tag = tag; r.readOnly = readOnly; r.savePassword = savePassword; r.tls = tls
        r.caName = caName; r.clientCertName = clientCertName
        r.sshEnabled = sshEnabled; r.sshHost = sshHost; r.sshPort = sshPort; r.sshUser = sshUser; r.sshAuth = sshAuth
        r.sshKeyName = sshKeyName; r.filePath = filePath; r.lastUsed = lastUsed; r.extra = extra ?? [:]
        return r
    }

    /// This app's bookmarks
    var bookmarks: [Slot: Data] {
        var b: [Slot: Data] = [:]
        b[.file] = fileBookmark; b[.sshKey] = sshKeyBookmark; b[.ca] = caBookmark; b[.clientCert] = clientCertBookmark; b[.clientKey] = clientKeyBookmark
        return b
    }
}

/// The connection list (shared by all windows). The list is in a file shared with OpenAsy Schema: a change made there
/// is read on its notification (and when the app comes to the front); every write is made on the file's latest state.
@MainActor @Observable
final class ConnectionStore {
    static let shared = ConnectionStore()
    static let log = Logger(subsystem: "com.openasy.database-client", category: "connections")

    /// App group: Info.plist OADBAppGroup (project.yml OA_DB_GROUP; the `.dev` group in debug builds)
    static let group = OAMacAppGroup.fromInfo("OADBAppGroup") ?? "47QC6LXXDZ.com.openasy.db"
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(AppInfo.folder, isDirectory: true)

    private let store: OADBConnectionStore
    private let marks = OADBConnectionBookmarks(product: AppInfo.folder)
    let keychain = OAKeychain(service: "com.openasy.db", accessGroup: ConnectionStore.group)
    let knownHosts = OAKnownHosts(url: ConnectionStore.support.appendingPathComponent("known_hosts.json"))
    private(set) var items: [SavedConnection] = []
    private var activeObserver: NSObjectProtocol?

    init() {
        store = OADBConnectionStore.appGroup(Self.group, app: AppInfo.id, fallback: Self.support)
        reload()
        store.observe { Task { @MainActor in ConnectionStore.shared.reload() } }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ConnectionStore.shared.reload() }
        }
        Self.log.notice("connections: \(self.store.url.path, privacy: .public), shared: \(self.store.isShared), keychain group: \(self.keychain.accessGroup ?? "-", privacy: .public), \(self.items.count) items")
    }

    /// Reads the shared file again (does not wake observers when nothing changed)
    func reload() {
        let list = store.load().map { SavedConnection($0, bookmarks: marks.all($0.id)) }
        if list != items { items = list }
    }

    func connection(_ id: String) -> SavedConnection? { items.first { $0.id == id } }

    /// Writing to the shared file: an error (for example a file from a newer version) is shown to the user and the list
    /// is read from the file again
    private func write(_ body: (inout [OADBConnection]) -> Void) {
        do {
            let list = try store.update(body)
            items = list.map { SavedConnection($0, bookmarks: marks.all($0.id)) }
        } catch {
            Self.log.error("connections write failed: \(error.localizedDescription, privacy: .public)")
            NSAlert(error: error).runModal()
            reload()
        }
    }

    func upsert(_ c: SavedConnection) {
        marks.setAll(c.id, c.bookmarks)
        let r = c.record
        write { list in
            if let i = list.firstIndex(where: { $0.id == r.id }) { list[i] = r } else { list.append(r) }
        }
    }

    func remove(_ id: String) {
        // Passwords are in the shared group: the connection goes from both apps
        keychain.delete(OADBConnection.dbAccount(id))
        keychain.delete(OADBConnection.sshAccount(id))
        marks.remove(id)
        write { $0.removeAll { $0.id == id } }
    }

    func touch(_ id: String) {
        let now = Date()
        write { list in
            if let i = list.firstIndex(where: { $0.id == id }) { list[i].lastUsed = now }
        }
    }

    /// Restoring a backup: the whole list changes (passwords are not in a backup). The list is shared, so in OpenAsy
    /// Schema too.
    func replaceAll(_ list: [SavedConnection]) {
        for c in list { marks.setAll(c.id, c.bookmarks) }
        marks.prune(keeping: Set(list.map(\.id)))
        write { $0 = list.map(\.record) }
    }

    // MARK: Connecting

    /// Connection settings: passwords from the keychain (or the one given for this time), files from bookmarks. When
    /// the connection was added in OpenAsy Schema, this app has no bookmark for its file: the file is chosen once more.
    func config(for conn: SavedConnection, password: String?, sshSecret: String?) throws -> (DBConnectConfig, [URL]) {
        // The window's copy may be stale: bookmarks chosen meanwhile are filled in from the store
        var c = conn
        let b = marks.all(c.id)
        c.fileBookmark = c.fileBookmark ?? b[.file]; c.sshKeyBookmark = c.sshKeyBookmark ?? b[.sshKey]; c.caBookmark = c.caBookmark ?? b[.ca]
        c.clientCertBookmark = c.clientCertBookmark ?? b[.clientCert]; c.clientKeyBookmark = c.clientKeyBookmark ?? b[.clientKey]
        var opened: [URL] = []
        func reselect(_ slot: SavedConnection.Slot, _ path: String?, _ bm: Data?) -> Data? {
            guard bm == nil, let path, !path.isEmpty, let fresh = Self.pickAgain(path) else { return bm }
            marks.set(c.id, slot, fresh)
            return fresh
        }
        func read(_ bm: Data?) -> Data? {
            guard let bm, let r = OAMacBookmark.resolve(bm) else { return nil }
            opened.append(r.url)
            return try? Data(contentsOf: r.url)
        }
        var cfg = DBConnectConfig(kind: c.kind, host: c.host, port: c.port, user: c.user,
                                  password: password ?? keychain.get(c.dbAccount), database: c.database, readOnly: c.readOnly)
        let tlsOn = c.tls != .off
        let ca = tlsOn ? reselect(.ca, c.caName, c.caBookmark) : c.caBookmark
        let cert = tlsOn ? reselect(.clientCert, c.clientCertName, c.clientCertBookmark) : c.clientCertBookmark
        // When the certificate was chosen again and there is no separate key file, the key is in the certificate file
        // (as on the connection sheet)
        let key = c.clientKeyBookmark ?? (c.clientCertBookmark == nil ? cert : nil)
        if key != c.clientKeyBookmark, let key { marks.set(c.id, .clientKey, key) }
        cfg.tls = OATLSConfig(mode: c.tls, caPEM: read(ca), clientCertPEM: read(cert), clientKeyPEM: read(key))
        if c.kind.isFile {
            guard let bm = reselect(.file, c.filePath, c.fileBookmark), let r = OAMacBookmark.resolve(bm) else { throw DBError("SQLite file is not accessible") }
            opened.append(r.url)
            if let fresh = r.refreshed { marks.set(c.id, .file, fresh) }
            cfg.file = r.url
        }
        if c.sshEnabled {
            let secret = sshSecret ?? keychain.get(c.sshAccount)
            let auth: OASSHConfig.Auth
            if c.sshAuth == .key {
                guard let key = read(reselect(.sshKey, c.sshKeyName, c.sshKeyBookmark)) else { throw DBError("SSH key file is not accessible") }
                auth = .key(key, passphrase: secret)
            } else { auth = .password(secret ?? "") }
            cfg.ssh = OASSHConfig(host: c.sshHost, port: c.sshPort, user: c.sshUser, auth: auth)
            cfg.sshTrusted = knownHosts.fingerprint(host: c.sshHost, port: c.sshPort)
        }
        if b != marks.all(c.id) { reload() }
        return (cfg, opened)
    }

    /// "Choose the file again": file access belongs to each app, and OpenAsy Schema's bookmark does not open here.
    /// `path`: the path or name in the record (`~/.ssh/id_ed25519`, `/.../shop.sqlite`, `ca.pem`); the panel opens in
    /// that folder.
    static func pickAgain(_ path: String) -> Data? {
        let expanded = (path as NSString).expandingTildeInPath.replacingOccurrences(of: NSHomeDirectory(), with: RealHome.real)
        let url = URL(fileURLWithPath: expanded)
        let p = NSOpenPanel()
        p.message = L.t("conn.reselect", ["name": url.lastPathComponent])
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        if path.contains("/") { p.directoryURL = url.deletingLastPathComponent() }
        guard p.runModal() == .OK, let picked = p.url else { return nil }
        return OAMacBookmark.make(picked)
    }
}

/// In the sandbox NSHomeDirectory() points inside the container; this is the user's real home folder
enum RealHome {
    static var real: String {
        let h = NSHomeDirectory()
        return h.components(separatedBy: "/Library/Containers").first ?? h
    }
}

/// Query history and saved queries (history.json, saved.json)
struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = DBID.make()
    var connectionID: String
    var connectionName: String
    var sql: String
    var date = Date()
    var ms: Double
    var rows: Int?
    var error: String?
}

struct SavedQuery: Codable, Identifiable, Hashable {
    var id = DBID.make()
    var name: String
    var sql: String
    /// When tied to one connection; nil: shown for every connection
    var connectionID: String?
    var created = Date()
}

@MainActor @Observable
final class QueryLibrary {
    static let shared = QueryLibrary()
    private let historyStore = OAMacJsonStore<[HistoryEntry]>(product: AppInfo.folder, name: "history")
    private let savedStore = OAMacJsonStore<[SavedQuery]>(product: AppInfo.folder, name: "saved")
    private(set) var history: [HistoryEntry] = []
    private(set) var saved: [SavedQuery] = []
    static let historyLimit = 2000

    init() {
        history = historyStore.load() ?? []
        saved = savedStore.load() ?? []
    }

    func record(_ e: HistoryEntry) {
        guard AppSettings.shared.keepHistory else { return }
        history.insert(e, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        historyStore.save(history)
    }

    func clearHistory() { history = []; historyStore.save(history) }
    func deleteHistory(_ id: String) { history.removeAll { $0.id == id }; historyStore.save(history) }

    func save(_ q: SavedQuery) {
        if let i = saved.firstIndex(where: { $0.id == q.id }) { saved[i] = q } else { saved.append(q) }
        savedStore.save(saved)
    }
    func deleteSaved(_ id: String) { saved.removeAll { $0.id == id }; savedStore.save(saved) }

    func replaceAll(history h: [HistoryEntry], saved s: [SavedQuery]) {
        history = h; saved = s
        historyStore.save(h); savedStore.save(s)
    }
}

/// Settings (UserDefaults: openasy.database-client.<key>)
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard
    private func key(_ k: String) -> String { "openasy.database-client.\(k)" }

    var editorFontSize: Double { didSet { d.set(editorFontSize, forKey: key("editorFontSize")) } }
    var pageSize: Int { didSet { d.set(pageSize, forKey: key("pageSize")) } }
    var maxRows: Int { didSet { d.set(maxRows, forKey: key("maxRows")) } }
    var keepHistory: Bool { didSet { d.set(keepHistory, forKey: key("keepHistory")) } }
    var autocomplete: Bool { didSet { d.set(autocomplete, forKey: key("autocomplete")) } }
    var confirmWrites: Bool { didSet { d.set(confirmWrites, forKey: key("confirmWrites")) } }
    var nullText: String { didSet { d.set(nullText, forKey: key("nullText")) } }

    init() {
        editorFontSize = d.object(forKey: "openasy.database-client.editorFontSize") as? Double ?? 12.5
        pageSize = d.object(forKey: "openasy.database-client.pageSize") as? Int ?? 500
        maxRows = d.object(forKey: "openasy.database-client.maxRows") as? Int ?? 50_000
        keepHistory = d.object(forKey: "openasy.database-client.keepHistory") as? Bool ?? true
        autocomplete = d.object(forKey: "openasy.database-client.autocomplete") as? Bool ?? true
        confirmWrites = d.object(forKey: "openasy.database-client.confirmWrites") as? Bool ?? true
        nullText = d.string(forKey: "openasy.database-client.nullText") ?? "NULL"
    }
}
