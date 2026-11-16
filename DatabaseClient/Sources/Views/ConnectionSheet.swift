import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OpenAsyMacKit

/// New or edited connection: system, general details, SSH tunnel, TLS, keychain, test
struct ConnectionSheet: View {
    @State var c: SavedConnection
    @State private var password = ""
    @State private var sshSecret = ""
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var pendingFingerprint: String?
    let done: (SavedConnection?, Bool) -> Void
    @Environment(\.oaMac) private var t
    private var store: ConnectionStore { .shared }
    private var isNew: Bool { store.connection(c.id) == nil }
    private var labelWidth: CGFloat { L.l10n.code == "de" || L.l10n.code == "fr" || L.l10n.code == "ru" || L.l10n.code == "nl" ? 150 : 130 }

    init(initial: SavedConnection, done: @escaping (SavedConnection?, Bool) -> Void) {
        _c = State(initialValue: initial)
        self.done = done
    }

    var body: some View {
        OASheet(isNew ? L.t("conn.new") : L.t("conn.edit"), subtitle: L.t("conn.privacy")) {
            VStack(alignment: .leading, spacing: 12) {
                OASegmented(DBEngines.supported.map { ($0, $0.displayName) }, selection: Binding(get: { c.kind }, set: { k in
                    if c.port == c.kind.defaultPort || c.port == 0 { c.port = k.defaultPort }
                    c.kind = k
                })).frame(maxWidth: 520).frame(maxWidth: .infinity)

                if c.kind.isFile {
                    OABox(L.t("conn.general")) { fileForm }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        OABox(L.t("conn.general")) { general }.frame(minWidth: 360)
                        VStack(spacing: 12) {
                            OABox { ssh }
                            OABox("TLS") { tls }
                        }.frame(minWidth: 340)
                    }
                }
                if let r = testResult { OANotice(r.ok ? .ok : .error, r.text) }
                if let f = pendingFingerprint {
                    HStack {
                        OANotice(.warn, L.t("ssh.unknown", ["f": f]))
                        Button(L.t("ssh.trust")) {
                            store.knownHosts.trust(host: c.sshHost, port: c.sshPort, fingerprint: f)
                            pendingFingerprint = nil
                            test()
                        }.buttonStyle(.oaSecondary)
                    }
                }
            }
        } footer: {
            Button(L.t("conn.test")) { test() }.buttonStyle(.oaSecondary).disabled(testing || !valid)
            if testing { ProgressView().controlSize(.small) }
            Spacer()
            Button(L.t("cancel")) { done(nil, false) }.buttonStyle(.oaSecondary).keyboardShortcut(.cancelAction)
            Button(L.t("save")) { save(); done(c, false) }.buttonStyle(.oaSecondary).disabled(!valid)
            Button(L.t("conn.saveConnect")) { save(); done(c, true) }.buttonStyle(.oaPrimary).keyboardShortcut(.defaultAction).disabled(!valid)
        }
        .frame(width: c.kind.isFile ? 560 : 900)
        .onAppear {
            if store.keychain.has(c.dbAccount) { password = "" }
        }
    }

    var valid: Bool { c.kind.isFile ? c.fileBookmark != nil : !c.host.trimmingCharacters(in: .whitespaces).isEmpty && c.port > 0 && (!c.sshEnabled || !c.sshHost.isEmpty) }

    @ViewBuilder var general: some View {
        VStack(alignment: .leading, spacing: 8) {
            OAFormRow(L.t("conn.name"), width: labelWidth) { TextField(c.host, text: $c.name).textFieldStyle(.oa) }
            OAFormRow(L.t("conn.hostPort"), width: labelWidth) {
                HStack(spacing: 6) {
                    TextField("db.example.com", text: $c.host).textFieldStyle(.oaMono)
                    TextField("", value: $c.port, format: .number.grouping(.never)).textFieldStyle(.oaMono).frame(width: 64).accessibilityLabel(L.t("conn.port"))
                }
            }
            OAFormRow(L.t("conn.database"), width: labelWidth) { TextField(c.kind == .postgres ? "postgres" : "", text: $c.database).textFieldStyle(.oaMono) }
            OAFormRow(L.t("conn.user"), width: labelWidth) { TextField("", text: $c.user).textFieldStyle(.oaMono) }
            OAFormRow(L.t("conn.password"), width: labelWidth) {
                OASecureField(store.keychain.has(c.dbAccount) ? L.t("conn.pwStored") : "", text: $password,
                              keychainNote: c.savePassword ? L.t("conn.keychainNote") : nil)
            }
            OAFormRow("", width: labelWidth) { Toggle(L.t("conn.savePw"), isOn: $c.savePassword) }
            if c.kind != .sqlite {
                OAFormRow(L.t("conn.defaultSchema"), width: labelWidth) { TextField(c.kind == .postgres || c.kind == .redshift ? "public" : "", text: $c.defaultSchema).textFieldStyle(.oaMono) }
            }
            tagRow
        }
    }

    var tagRow: some View {
        Group {
            OAFormRow(L.t("conn.tag"), width: labelWidth) {
                OASegmented(SavedConnection.Tag.allCases.map { ($0, L.t("conn.tag.\($0.rawValue)")) }, selection: $c.tag)
            }
            OAFormRow("", width: labelWidth) { Toggle(L.t("conn.readOnly"), isOn: $c.readOnly) }
        }
    }

    @ViewBuilder var ssh: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $c.sshEnabled) { Text(L.t("conn.ssh")).font(OAMacFont.sans(12.5, .semibold)) }.toggleStyle(.switch)
            if c.sshEnabled {
                OAFormRow(L.t("conn.sshHost"), width: labelWidth) {
                    HStack(spacing: 6) {
                        TextField("bastion.example.com", text: $c.sshHost).textFieldStyle(.oaMono)
                        TextField("", value: $c.sshPort, format: .number.grouping(.never)).textFieldStyle(.oaMono).frame(width: 52).accessibilityLabel(L.t("conn.port"))
                    }
                }
                OAFormRow(L.t("conn.sshUser"), width: labelWidth) { TextField("", text: $c.sshUser).textFieldStyle(.oaMono) }
                OAFormRow(L.t("conn.sshAuth"), width: labelWidth) {
                    OASegmented([(SavedConnection.SSHAuth.key, L.t("conn.sshAuth.key")), (.password, L.t("conn.password"))], selection: $c.sshAuth)
                }
                if c.sshAuth == .key {
                    OAFormRow(L.t("conn.sshKey"), width: labelWidth) {
                        HStack {
                            Text(c.sshKeyName ?? L.t("conn.none")).font(OAMacFont.mono(12)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(L.t("conn.pick")) { pick(.sshKey) }.buttonStyle(.oa(.secondary, .small))
                        }
                    }
                }
                OAFormRow(c.sshAuth == .key ? L.t("conn.sshPassphrase") : L.t("conn.sshPassword"), width: labelWidth) {
                    SecureField(store.keychain.has(c.sshAccount) ? L.t("conn.pwStored") : "", text: $sshSecret).textFieldStyle(.oa)
                }
                if let f = store.knownHosts.fingerprint(host: c.sshHost, port: c.sshPort) {
                    OAFormRow(L.t("ssh.fingerprint"), width: labelWidth) {
                        HStack {
                            Text(f).font(OAMacFont.mono(11)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Button(L.t("ssh.forget")) { store.knownHosts.forget(host: c.sshHost, port: c.sshPort); c.sshHost += "" }.buttonStyle(.oa(.plain, .small))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder var tls: some View {
        VStack(alignment: .leading, spacing: 8) {
            OAFormRow(L.t("conn.tlsMode"), width: labelWidth) {
                Picker("", selection: $c.tls) {
                    ForEach(OATLSConfig.Mode.allCases, id: \.self) { Text(L.t("conn.tls.\($0.rawValue)")).tag($0) }
                }.labelsHidden()
            }
            if c.tls != .off {
                OAFormRow(L.t("conn.ca"), width: labelWidth) {
                    HStack {
                        Text(c.caName ?? L.t("conn.systemTrust")).font(OAMacFont.sans(12)).lineLimit(1)
                        Spacer()
                        if c.caBookmark != nil { Button(L.t("conn.clear")) { c.caBookmark = nil; c.caName = nil }.buttonStyle(.oa(.plain, .small)) }
                        Button(L.t("conn.pick")) { pick(.ca) }.buttonStyle(.oa(.secondary, .small))
                    }
                }
                OAFormRow(L.t("conn.clientCert"), width: labelWidth) {
                    HStack {
                        Text(c.clientCertName ?? L.t("conn.optional")).font(OAMacFont.sans(12)).lineLimit(1)
                        Spacer()
                        Button(L.t("conn.pick")) { pick(.clientCert) }.buttonStyle(.oa(.secondary, .small))
                    }
                }
            }
        }
    }

    @ViewBuilder var fileForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            OAFormRow(L.t("conn.name"), width: labelWidth) { TextField(c.filePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "", text: $c.name).textFieldStyle(.oa) }
            OAFormRow(L.t("conn.file"), width: labelWidth) {
                HStack {
                    Text(c.filePath ?? L.t("conn.none")).font(OAMacFont.mono(12)).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button(L.t("sqlite.open")) { pick(.sqlite) }.buttonStyle(.oa(.secondary, .small))
                    Button(L.t("sqlite.new")) { pick(.sqliteNew) }.buttonStyle(.oa(.secondary, .small))
                }
            }
            tagRow
        }
    }

    enum PickKind { case sshKey, ca, clientCert, sqlite, sqliteNew }

    func pick(_ k: PickKind) {
        if k == .sqliteNew {
            let p = NSSavePanel()
            p.nameFieldStringValue = L.t("sqlite.untitled") + ".sqlite"
            p.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
            guard p.runModal() == .OK, let url = p.url else { return }
            FileManager.default.createFile(atPath: url.path, contents: nil)
            c.fileBookmark = OAMacBookmark.make(url); c.filePath = url.path
            return
        }
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.allowsMultipleSelection = false
        p.showsHiddenFiles = k == .sshKey
        if k == .sshKey { p.directoryURL = URL(fileURLWithPath: NSHomeDirectory().components(separatedBy: "/Library/Containers").first! + "/.ssh") }
        guard p.runModal() == .OK, let url = p.url else { return }
        let bm = OAMacBookmark.make(url)
        switch k {
        case .sshKey: c.sshKeyBookmark = bm; c.sshKeyName = url.path.replacingOccurrences(of: NSHomeDirectory().components(separatedBy: "/Library/Containers").first!, with: "~")
        case .ca: c.caBookmark = bm; c.caName = url.lastPathComponent
        case .clientCert:
            // The certificate and the key can be in the same PEM file; a separate key file is a second choice
            c.clientCertBookmark = bm; c.clientCertName = url.lastPathComponent
            let k2 = NSOpenPanel()
            k2.message = L.t("conn.clientKey")
            if k2.runModal() == .OK, let ku = k2.url { c.clientKeyBookmark = OAMacBookmark.make(ku) } else { c.clientKeyBookmark = bm }
        case .sqlite: c.fileBookmark = bm; c.filePath = url.path
        case .sqliteNew: break
        }
    }

    func save() {
        if c.name.trimmingCharacters(in: .whitespaces).isEmpty { c.name = c.displayName }
        if c.savePassword, !password.isEmpty { store.keychain.set(password, for: c.dbAccount) }
        if !c.savePassword { store.keychain.delete(c.dbAccount) }
        if !sshSecret.isEmpty { store.keychain.set(sshSecret, for: c.sshAccount) }
        store.upsert(c)
    }

    func test() {
        testing = true
        testResult = nil
        let conn = c
        Task {
            do {
                var (cfg, urls) = try store.config(for: conn, password: password.isEmpty ? nil : password, sshSecret: sshSecret.isEmpty ? nil : sshSecret)
                defer { for u in urls { u.stopAccessingSecurityScopedResource() } }
                cfg.timeout = 10
                let t0 = Date()
                let s = try await DBEngines.connect(cfg)
                let ms = Date().timeIntervalSince(t0) * 1000
                var parts = [s.kind.displayName + " " + s.serverVersion]
                if conn.sshEnabled { parts.append(L.t("conn.viaSSH")) }
                if conn.tls != .off { parts.append("TLS") }
                parts.append(L.l10n.ms(ms))
                testResult = (true, L.t("conn.testOkFull", ["detail": parts.joined(separator: " · ")]))
                await s.close()
            } catch OASSHError.unknownHost(let f) {
                pendingFingerprint = f
            } catch {
                testResult = (false, L.err(error))
            }
            testing = false
        }
    }
}

/// While connecting: a password or the SSH fingerprint confirmation
struct PromptSheet: View {
    let ws: Workspace
    let prompt: Workspace.Prompt
    @State private var text = ""
    @Environment(\.oaMac) private var t
    var body: some View {
        switch prompt {
        case .password(let name):
            OASheet(L.t("conn.passwordFor", ["name": name])) {
                SecureField(L.t("conn.password"), text: $text).textFieldStyle(.oa).frame(width: 340)
            } footer: {
                Spacer()
                Button(L.t("cancel")) { ws.prompt = nil }.buttonStyle(.oaSecondary).keyboardShortcut(.cancelAction)
                Button(L.t("conn.connect")) { ws.prompt = nil; Task { await ws.connect(password: text) } }.buttonStyle(.oaPrimary).keyboardShortcut(.defaultAction)
            }
        case .fingerprint(let host, let port, let f):
            OASheet(L.t("ssh.trustTitle"), subtitle: L.t("ssh.trustLead", ["host": "\(host):\(port)"])) {
                Text(f).font(OAMacFont.mono(13)).foregroundStyle(t.text).textSelection(.enabled).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading).background(t.panel2, in: RoundedRectangle(cornerRadius: 8))
            } footer: {
                Spacer()
                Button(L.t("cancel")) { ws.prompt = nil; ws.state = .idle }.buttonStyle(.oaSecondary).keyboardShortcut(.cancelAction)
                Button(L.t("ssh.trust")) { Task { await ws.trust(host, port, f) } }.buttonStyle(.oaPrimary).keyboardShortcut(.defaultAction)
            }
            .frame(width: 520)
        }
    }
}
