import XCTest
import OpenAsyMacKit
@testable import DatabaseClient

@MainActor
final class DatabaseClientTests: XCTestCase {
    final class Src: OADataGridSource {
        var gridColumns: [OAGridColumn] { [OAGridColumn(title: "id", numeric: true), OAGridColumn(title: "name"), OAGridColumn(title: "note")] }
        let rows: [[String?]] = [["1", "O'Brien, Ltd", nil], ["2", "Ayşe \"A\"", "x"]]
        var gridRowCount: Int { rows.count }
        func gridValue(row: Int, column: Int) -> (text: String, isNull: Bool) { (rows[row][column] ?? "", rows[row][column] == nil) }
    }

    func testExportCSV() {
        let csv = Exporter.render(Src(), rows: nil, format: .csv, table: nil, dialect: nil)
        XCTAssertEqual(csv, "id,name,note\r\n1,\"O'Brien, Ltd\",\r\n2,\"Ayşe \"\"A\"\"\",x\r\n")
    }

    func testExportJSONTypesAndNull() throws {
        let json = Exporter.render(Src(), rows: [0], format: .json, table: nil, dialect: nil)
        let arr = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
        XCTAssertEqual(arr[0]["id"] as? Int, 1)
        XCTAssertTrue(arr[0]["note"] is NSNull)
    }

    func testExportInsertPerDialect() {
        XCTAssertEqual(Exporter.render(Src(), rows: [0], format: .sql, table: "t", dialect: MySQLDialect()),
                       "INSERT INTO `t` (`id`, `name`, `note`) VALUES ('1', 'O''Brien, Ltd', NULL);\n")
        XCTAssertEqual(Exporter.render(Src(), rows: [0], format: .sql, table: "t", dialect: PostgresDialect()),
                       "INSERT INTO \"t\" (\"id\", \"name\", \"note\") VALUES ('1', 'O''Brien, Ltd', NULL);\n")
    }

    func testCSVParse() {
        XCTAssertEqual(Exporter.parseCSV("a;b\n1;\"x;y\"\n\"q\"\"r\";2\n"), [["a", "b"], ["1", "x;y"], ["q\"r", "2"]])
        XCTAssertEqual(Exporter.parseCSV("a,b\r\n1,2\r\n"), [["a", "b"], ["1", "2"]])
    }

    func testFormatter() {
        XCTAssertEqual(SQLFormat.format("select a, b from t where x = 1 order by a"), "SELECT a, b\nFROM t\nWHERE x = 1\nORDER BY a\n")
    }

    func testSampleDatabaseBuilds() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sample-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let s = try await DBEngines.connect(DBConnectConfig(kind: .sqlite, file: url))
        for sql in Sample.sql(categories: "A|B", products: "P1|P2|P3") { _ = try await s.execute(sql) }
        let n = try await s.strings("SELECT COUNT(*) FROM orders")
        XCTAssertEqual(n.first, "60")
        await s.close()
    }

    // MARK: Shared connections and links to OpenAsy Schema

    func testSharedRecordSplitsBookmarksAndKeepsExtra() throws {
        var c = SavedConnection()
        c.name = "Production"; c.kind = .postgres; c.tag = .production; c.sshEnabled = true; c.sshAuth = .password
        c.fileBookmark = Data([1]); c.sshKeyBookmark = Data([2]); c.caBookmark = Data([3]); c.caName = "ca.pem"
        c.extra = ["schemaProject": .string("~/repo")]
        let r = c.record
        XCTAssertEqual(r.extra["schemaProject"], .string("~/repo"))
        XCTAssertEqual(r.caName, "ca.pem")
        let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        XCTAssertFalse(json.contains("Bookmark"), "bookmarks never enter the shared record")
        XCTAssertEqual(c.bookmarks, [.file: Data([1]), .sshKey: Data([2]), .ca: Data([3])])
        XCTAssertEqual(SavedConnection(r, bookmarks: c.bookmarks), c)
        XCTAssertEqual(c.dbAccount, "conn:\(c.id):db")
    }

    /// A connection list as a backup holds it (an array, bookmarks inside, dates in the default encoding) decodes
    func testBackupConnectionsDecode() throws {
        let raw = #"[{"id":"a","name":"Local","kind":"sqlite","host":"localhost","port":0,"user":"","database":"","defaultSchema":"","tag":"none","readOnly":false,"savePassword":true,"tls":"off","sshEnabled":false,"sshHost":"","sshPort":22,"sshUser":"","sshAuth":"key","filePath":"/x.sqlite","fileBookmark":"AAEC","lastUsed":784000000}]"#
        let list = try JSONDecoder().decode([SavedConnection].self, from: Data(raw.utf8))
        XCTAssertEqual(list.first?.fileBookmark, Data([0, 1, 2]))
        XCTAssertNil(list.first?.extra)
        XCTAssertEqual(list.first?.record.lastUsed, Date(timeIntervalSinceReferenceDate: 784000000))
    }

    func testIncomingLinks() {
        let open = LinkRouter.parse(URL(string: "openasy-database-client://open?conn=c1&schema=public&table=orders")!)
        XCTAssertEqual(open, .init(kind: .open, conn: "c1", schema: "public", table: "orders"))
        XCTAssertEqual(open.flatMap { LinkRouter.action($0, sql: nil) }, .table(schema: "public", name: "orders"))
        XCTAssertEqual(LinkRouter.parse(URL(string: "openasy-database-client://open?conn=c1&schema=s")!).flatMap { LinkRouter.action($0, sql: nil) }, .schema("s"))
        XCTAssertNil(LinkRouter.parse(URL(string: "openasy-database-client://open?conn=c1")!).flatMap { LinkRouter.action($0, sql: nil) })

        let q = LinkRouter.parse(URL(string: "openasy-database-client://query?conn=c1&file=../../etc/passwd")!)
        XCTAssertEqual(q?.file, "passwd", "a file name cannot leave the folder")
        XCTAssertEqual(q.flatMap { LinkRouter.action($0, sql: "SELECT 1") }, .query(schema: nil, sql: "SELECT 1"))
        XCTAssertEqual(LinkRouter.parse(URL(string: "openasy-database-client://query?conn=c1&sql=SELECT%202")!).flatMap { LinkRouter.action($0, sql: nil) },
                       .query(schema: nil, sql: "SELECT 2"))

        XCTAssertNil(LinkRouter.parse(URL(string: "openasy-database-client://open")!), "a connection id is required")
        XCTAssertNil(LinkRouter.parse(URL(string: "openasy-database-client://delete?conn=c1")!))
        XCTAssertNil(LinkRouter.parse(URL(string: "openasy-schema://open?conn=c1")!))
    }

    func testSchemaImportURL() {
        XCTAssertEqual(SchemaApp.importURL(conn: "c1", schema: "public").absoluteString, "openasy-schema://import?conn=c1&schema=public")
        XCTAssertEqual(SchemaApp.importURL(conn: "c 1", schema: "").absoluteString, "openasy-schema://import?conn=c%201")
    }
}
