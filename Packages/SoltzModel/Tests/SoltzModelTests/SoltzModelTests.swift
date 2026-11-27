// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SoltzModel
import Testing

let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
let reader = DataReader(directory: fixtures)

func source(_ file: String) throws -> [JSONValue] {
    try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: fixtures.appending(path: file)))
}

func encoded(_ value: some Encodable) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

func record<F: Identifiable>(_ result: ReadResult<Lossless<F>>, _ id: String) throws -> Lossless<F> where F.ID == String {
    try #require(result.records.first { $0.id == id })
}

func encodedAll<R: Encodable>(_ result: ReadResult<R>) throws -> (records: [JSONValue], failures: [String]) {
    (try result.records.map(encoded), result.failures)
}

@Test(arguments: ["connections.json", "identities.json", "ssh_keys.json", "folders.json", "known_hosts.json"])
func everyRecordReencodesToItsSourceJSON(file: String) throws {
    let (records, failures) = switch file {
    case "connections.json": try encodedAll(reader.connections())
    case "identities.json": try encodedAll(reader.identities())
    case "ssh_keys.json": try encodedAll(reader.sshKeys())
    case "folders.json": try encodedAll(reader.folders())
    default: try encodedAll(reader.knownHosts())
    }
    let src = try source(file)
    #expect(records.count + failures.count == src.count)
    #expect(failures.count == (file == "connections.json" ? 1 : 0))
    for json in records {
        #expect(json == src.first { $0["id"] == json["id"] })
    }
}

@Test func aRecordThatFailsIsReportedNotDropped() throws {
    let result = try reader.connections()
    #expect(result.failures.count == 1)
    #expect(result.failures.first?.hasPrefix("connections.json[7]: ") == true)
    #expect(Set(result.records).count == 7)
}

@Test func maximalConnectionDecodesEveryField() throws {
    let c = try record(reader.connections(), "conn-max")
    #expect(c.name == "web" && c.host == "example.com" && c.port == 22 && c.username == "root")
    #expect(c.authType == .key && c.tags == ["prod", "eu"])
    #expect(c.createdAt == "2026-01-01T00:00:00Z" && c.lastUsedAt == "2026-01-05T00:00:00Z")
    #expect(c.distro == "ubuntu" && c.icon == "server")
    #expect(c.identityID == "id-1" && c.keyID == "key-1" && c.folderID == "folder-1" && c.vaultID == "team")
    #expect(c.jumpHosts.count == 1)
    #expect(c.jumpHosts[0].connectionID == "c-9" && c.jumpHosts[0].host == "bastion")
    #expect(c.jumpHosts[0].port == 2222 && c.jumpHosts[0].username == "jump" && c.jumpHosts[0].identityID == "id-2")
    #expect(c.envVars.map(\.id) == ["ev-1"] && c.envVars[0].key == "TERM" && c.envVars[0].value == "xterm")
    #expect(c.agentForwarding && c.legacyAlgorithms && c.askVarsEachTime && c.pinned && c.pingDisabled)
    #expect(c.preCommand == "echo hi" && c.postCommand == "echo bye")
    #expect(c.preSnippetID == "snip-pre" && c.postSnippetID == "snip-post")
    #expect(c.terminalEncoding == "utf-8")
    #expect(c.shellIntegration == true && c.keepalivePreset == .fast && c.persistSession == false)
    #expect(c.proxy?.mode == .socks5 && c.proxy?.host == "proxy.local" && c.proxy?.port == 1080)
    #expect(c.proxy?.username == "px")
    #expect(c.portKnock?.enabled == true && c.portKnock?.delayMs == 100)
    #expect(c.portKnock?.settleMs == 250 && c.portKnock?.windowSecs == 30)
    #expect(c.connectionType == .ssh)
    #expect(c.serialPort == "/dev/ttyU0" && c.serialBaud == 9600 && c.serialDataBits == 8)
    #expect(c.serialParity == .even && c.serialStopBits == 1 && c.serialFlowControl == .rtsCts)
    #expect(c.serialAutoReconnect == true)
    #expect(c.ftpSecure && c.webdavURL == "https://h/dav/" && c.webSecure)
    #expect(c.notes == "maintenance window: Sat")
    #expect(c.updatedAt == "2026-01-02T00:00:00Z" && c.deletedAt == nil)
    #expect(c.clocks == ["name": "2026-01-01T00:00:00Z", "host": "2026-01-02T00:00:00Z"])
}

@Test func minimalConnectionGetsRustDefaultsWithoutInventingKeys() throws {
    let c = try record(reader.connections(), "conn-min")
    #expect(c.host == "" && c.port == 0 && c.username == "" && c.authType == .password)
    #expect(c.vaultID == "personal" && c.connectionType == .ssh)
    #expect(c.jumpHosts.isEmpty && c.envVars.isEmpty && !c.agentForwarding && !c.pinned && !c.ftpSecure)
    #expect(c.name == nil && c.lastUsedAt == nil && c.deletedAt == nil && c.proxy == nil)
    #expect(try c.json().keys.sorted() == ["clocks", "created_at", "id", "tags", "updated_at"])
}

@Test func absentAndNullBothDecodeToNilAndBothSurvive() throws {
    let all = try reader.connections()
    let rustWritten = try record(all, "conn-rust-written")
    let minimal = try record(all, "conn-min")
    #expect(rustWritten.name == nil && minimal.name == nil)
    #expect(try rustWritten.json()["name"] == JSONValue.null)
    #expect(try minimal.json()["name"] == nil)
    // Rust skips these when None; the record never had them.
    #expect(try rustWritten.json()["shell_integration"] == nil)
    #expect(try rustWritten.json()["notes"] == nil)
}

@Test func editsTouchOnlyChangedKeysAndKeepUnknownFields() throws {
    var c = try record(reader.connections(), "conn-future")
    c.host = "moved.example.com"
    c.name = nil
    c.jumpHosts[0].port = 2200
    let out = try c.json()
    #expect(out["host"] == "moved.example.com")
    #expect(out["name"] == JSONValue.null)
    #expect(out["jump_hosts"]?.array?.first?["port"] == 2200)
    #expect(out["jump_hosts"]?.array?.first?["via_proxy"] == true)
    #expect(out["jump_hosts"]?.array?.first?["host"] == JSONValue.null)
    #expect(out["env_vars"]?.array?.first?["secret"] == false)
    #expect(out["proxy"]?["dns_remote"] == true)
    #expect(out["port_knock"]?["protocol"] == "udp")
    #expect(out["mosh"] == ["enabled": true, "port_range": [60000, 61000], "prediction": "adaptive", "ratio": 0.75])
    #expect(out["big_counter"] == .int(18_014_398_509_481_985))
    #expect(out["pinned"] == nil)
    #expect(out["clocks"]?["mosh"] == "2026-11-01T00:00:00Z")
}

@Test func unknownEnumValuesSurvive() throws {
    let c = try record(reader.connections(), "conn-future")
    #expect(c.authType.rawValue == "kerberos" && c.authType != .password && c.authType != .key)
    #expect(c.connectionType.rawValue == "telnet")
    #expect(c.keepalivePreset?.rawValue == "ultra")
    #expect(c.proxy?.mode.rawValue == "socks4")
    #expect(c.serialParity?.rawValue == "mark" && c.serialFlowControl?.rawValue == "dtr-dsr")
    var edited = c
    edited.notes = "touched"
    let out = try edited.json()
    #expect(out["auth_type"] == "kerberos" && out["connection_type"] == "telnet" && out["keepalive_preset"] == "ultra")
    #expect(out["proxy"]?["mode"] == "socks4" && out["serial_parity"] == "mark")
}

@Test func legacyShapesMigrateLikeRustButRoundTripVerbatim() throws {
    var c = try record(reader.connections(), "conn-legacy")
    #expect(c.vaultID == "legacy-team" && c.shellIntegration == false && c.authType == .password)
    #expect(try c.json()["vault_ids"] == ["legacy-team", "x"])
    #expect(try c.json()["vault_id"] == nil)

    c.pinned = true
    let out = try c.json()
    #expect(out["pinned"] == true && out["vault_id"] == "legacy-team" && out["shell_integration"] == false)
    #expect(out["vault_ids"] == nil && out["shell_integration_disabled"] == nil && out["auth_type"] == nil)

    // migrate_vault_id cases: bare string, empty array, absent.
    #expect(try record(reader.identities(), "id-legacy").vaultID == "solo")
    #expect(try record(reader.sshKeys(), "key-old").vaultID == "personal")
    // Folders load without that migration in Rust: serde's default wins over `vault_ids`.
    let folder = try record(reader.folders(), "folder-min")
    #expect(folder.vaultID == "personal" && folder.objectType == .connection)
}

@Test func otherRustEntitiesApplyTheirDefaults() throws {
    let kh = try record(reader.knownHosts(), "kh-old")
    #expect(kh.clocks.isEmpty && kh.vaultID == "personal" && kh.port == 2222)
    #expect(try kh.json()["clocks"] == nil)

    let identity = try record(reader.identities(), "id-gone")
    #expect(identity.deletedAt == "2026-04-01T00:00:00Z" && identity.username == "temp")
    let key = try record(reader.sshKeys(), "key-1")
    #expect(key.keyType == "ed25519" && key.folderID == nil)
    let folder = try record(reader.folders(), "folder-keys")
    #expect(folder.objectType == .keychain && folder.deletedAt != nil && folder.parentFolderID == nil)
}

@Test func vaultsComeFromTheSettingsBundle() throws {
    let result = try reader.vaults()
    #expect(result.failures.isEmpty)
    #expect(result.records.map(\.id) == ["personal", "v-future", "v-old", "v-team"])
    let byID = Dictionary(uniqueKeysWithValues: result.records.map { ($0.id, $0) })
    #expect(byID["v-team"]?.teamID == "team-1" && byID["v-team"]?.name == "")
    #expect(byID["v-old"]?.deletedAt == "2026-04-01T00:00:00.000Z")

    let settings = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixtures.appending(path: "settings.json")))
    for vault in result.records {
        #expect(try encoded(vault) == settings["sections"]?["vaults"]?["data"]?[vault.id])
    }
}

@Test func readerTreatsMissingFilesAsEmptyAndRejectsNonArrays() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "soltz-model-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let empty = DataReader(directory: dir)
    #expect(try empty.connections().records.isEmpty)
    #expect(try empty.vaults().records.isEmpty)
    try Data(#"{"id":"a"}"#.utf8).write(to: dir.appending(path: "folders.json"))
    #expect(throws: (any Error).self) { try empty.folders() }
}
