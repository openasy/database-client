#if DEBUG
import AppKit
import SwiftUI
import OpenAsyMacKit

/// Screenshots and tests (debug builds only): DBCLIENT_DEMO=<screen> sets the screen up once connected,
/// DBCLIENT_SHOT=<name> writes a picture of the window into the container and quits the app (focus is never taken: open
/// -g).
@MainActor
enum Demo {
    static var screen: String? { ProcessInfo.processInfo.environment["DBCLIENT_DEMO"] }

    /// Screens without a connection: `newConn` opens the new connection sheet on the welcome window, `sample` creates
    /// the sample database and its connection (a later run opens it with DBCLIENT_OPEN)
    static func runIdle(_ ws: Workspace) {
        switch screen {
        case "newConn": ws.editingConnection = SavedConnection()
        case "sample": openSample { _ in }
        default: break
        }
    }

    static func run(_ ws: Workspace) async {
        guard let s = screen else { return }
        let sleep = { (ms: UInt64) in try? await Task.sleep(nanoseconds: ms * 1_000_000) }
        switch s {
        case "query", "plan", "export":
            let q = ws.tabs.first as? QueryTab ?? ws.newQueryTab()
            q.title = L.t("demo.queryTitle")
            q.sql = "-- " + L.t("demo.queryComment") + "\nSELECT o.id, o.customer_id, c.name AS customer,\n       o.total, o.status, o.created_at, o.meta\nFROM orders o\nJOIN customers c ON c.id = o.customer_id\nWHERE o.created_at > now() - interval '30 days'\n  AND o.status <> 'cancelled'\nORDER BY o.created_at DESC\nLIMIT 20;\n"
            q.savedSQL = ""
            ws.openTable("orders")
            ws.selectedTab = q.id
            await sleep(600)
            q.editor.select(NSRange(location: 60, length: 0))
            q.run(all: true)
            await sleep(1500)
            if s == "plan" { q.explain() }
            if let r = q.current { r.requested = [2]; r.gridSelectionChanged(rows: [2], column: 6); r.version += 1; ws.selectionTick += 1 }
        case "data":
            ws.openTable("orders", mode: .data)
            await sleep(1500)
            if let t = ws.selected as? TableTab {
                t.filters = [DBFilter(column: "status", op: .eq, value: "shipped")]
                await t.reloadData()
                t.setValue(.text("delivered"), row: 2, column: 3)
                t.deleteRows([5])
                t.addRow()
                t.requested = [2]; t.selectedRows = [2]; t.selectedColumn = 3; t.version += 1
                ws.selectionTick += 1
            }
        case "structure", "structurePreview":
            ws.openTable("orders", mode: .structure)
            await sleep(1500)
            if let t = ws.selected as? TableTab, var d = t.draft {
                if let i = d.columns.firstIndex(where: { $0.name == "status" }) { d.columns[i].type = "varchar(32)"; t.selectedField = d.columns[i].id }
                d.columns.append(DBColumn(name: "note", type: "text"))
                t.draft = d
                if s == "structurePreview" { t.showStructurePreview = true }
            }
        case "conn":
            ws.editingConnection = ws.conn
        case "users":
            ws.openSingleton(UsersTab.self) { UsersTab(ws: ws) }
            if let u = ws.selected as? UsersTab {
                await u.load()
                u.selected = "rapor_okur"
                await u.loadGrants()
                u.grants.set("orders", "UPDATE", true)
                u.grants.set("reviews", "SELECT", false)
            }
        case "sync":
            ws.openSingleton(SyncTab.self) { SyncTab(ws: ws) }
            if let st = ws.selected as? SyncTab {
                st.sourceSchema = "staging"
                st.targetSchema = "public"
                await st.compare()
                st.selectedChange = st.changes.first { $0.object == "orders" }?.id
            }
        case "history":
            for sql in ["SELECT count(*) FROM orders", "SELECT * FROM customers WHERE city = 'İzmir'", "UPDATE orders SET status = 'paid' WHERE id = 10412"] {
                _ = try? await ws.execute(sql)
            }
            QueryLibrary.shared.save(SavedQuery(name: L.t("demo.queryTitle"), sql: "SELECT * FROM orders ORDER BY created_at DESC LIMIT 20", connectionID: ws.conn?.id))
            ws.openSingleton(HistoryTab.self) { HistoryTab(ws: ws) }
        default: break
        }
    }

    /// A picture of the window (title and toolbar included) to the container's <name>.png; then quit
    static func shoot(after seconds: Double) {
        guard let name = ProcessInfo.processInfo.environment["DBCLIENT_SHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let diag = NSApp.windows.map { "\($0.className) \(Int($0.frame.width))x\(Int($0.frame.height)) visible=\($0.isVisible)" }.joined(separator: "\n")
            let ddir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(AppInfo.folder + "/shots", isDirectory: true)
            try? FileManager.default.createDirectory(at: ddir, withIntermediateDirectories: true)
            try? diag.write(to: ddir.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
            if ProcessInfo.processInfo.environment["DBCLIENT_SHOT_EXTERNAL"] != nil,
               let w = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) {
                try? "\(w.windowNumber)".write(to: ddir.appendingPathComponent("\(name).wid"), atomically: true, encoding: .utf8)
                return
            }
            guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }),
                  let frame = w.contentView?.superview else {
                NSLog("Database Client shot: no window (%d)", NSApp.windows.count)
                exit(0); return
            }
            if let sheet = w.attachedSheet { _ = sheet }
            // First from the window server (materials and the toolbar's glass included; no permission is needed for the
            // app's own window), otherwise from the view
            var img: NSBitmapImageRep
            if let cg = layerImage(frame) { img = NSBitmapImageRep(cgImage: cg) } else {
                let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)!
                frame.cacheDisplay(in: frame.bounds, to: rep)
                img = rep
            }
            let rep = img
            // An open sheet is a separate window: it is drawn on top
            if let sheet = w.attachedSheet, let sv = sheet.contentView?.superview, let srep = sv.bitmapImageRepForCachingDisplay(in: sv.bounds) {
                sv.cacheDisplay(in: sv.bounds, to: srep)
                let out = NSImage(size: frame.bounds.size)
                out.lockFocus()
                rep.draw(in: frame.bounds)
                NSColor.black.withAlphaComponent(0.25).setFill()
                frame.bounds.fill(using: .sourceAtop)
                let x = (frame.bounds.width - sheet.frame.width) / 2
                let y = frame.bounds.height - sheet.frame.height - (w.frame.height - w.contentLayoutRect.height)
                srep.draw(in: NSRect(x: x, y: y, width: sheet.frame.width, height: sheet.frame.height))
                out.unlockFocus()
                if let tiff = out.tiffRepresentation, let r = NSBitmapImageRep(data: tiff) { img = r }
            }
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(AppInfo.folder + "/shots", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? img.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
            exit(0)
        }
    }
}

/// Rendering the layer tree (the view cache skips material and sidebar hosts)
func layerImage(_ v: NSView) -> CGImage? {
    guard let layer = v.layer else { return nil }
    let scale = v.window?.backingScaleFactor ?? 2
    let w = Int(v.bounds.width * scale), h = Int(v.bounds.height * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: scale, y: scale)
    if !v.isFlipped { } else { ctx.translateBy(x: 0, y: v.bounds.height); ctx.scaleBy(x: 1, y: -1) }
    layer.render(in: ctx)
    return ctx.makeImage()
}

/// CGWindowListCreateImage (removed from the SDK, still in the system): only the app's own window
func ownWindowImage(_ number: Int) -> CGImage? {
    typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    guard let h = dlopen(nil, RTLD_NOW), let sym = dlsym(h, "CGWindowListCreateImage") else { return nil }
    let f = unsafeBitCast(sym, to: Fn.self)
    // kCGWindowListOptionIncludingWindow = 8, kCGWindowImageBoundsIgnoreFraming = 1
    return f(.null, 8, UInt32(number), 1)?.takeRetainedValue()
}
#endif
