// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SoltzCore
import Testing

/// Entities, known hosts and the vault through the bindings, each test in its own
/// temp data directory. The keychain is the in-memory one: no login-keychain item.
struct StorageTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "soltz-\(UUID().uuidString)")
    var path: String { dir.path(percentEncoded: false) }

    func core() throws -> Core { try Core.withDataDir(dataDir: path, keychain: .memory) }

    func rows(_ json: String) throws -> [[String: Any]] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }

    @Test func anEntityIsSavedListedAndTombstoned() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let core = try core()
        let row = """
            {"id":"c1","host":"example.com","port":22,"username":"root","tags":[],
             "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z",
             "deleted_at":null,"clocks":{"host":"2026-01-01T00:00:00Z"}}
            """
        try await core.entitySave(kind: .connections, row: row)
        let listed = try rows(try await core.entityList(kind: .connections))
        #expect(listed.map { $0["id"] as? String } == ["c1"])
        #expect(listed.first?["vault_id"] as? String == "personal", "upstream's default")

        try await core.entityDelete(kind: .connections, id: "c1")
        #expect(try await core.entityList(kind: .connections) == "[]")
        let stored = try rows(String(decoding: try Data(contentsOf: dir.appending(path: "connections.json")), as: UTF8.self))
        #expect(stored.first?["deleted_at"] is String, "the tombstone stays on disk")
    }

    @Test func knownHostsPersistAcrossCores() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("""
            [{"id":"kh1","host":"example.com","port":22,"fingerprint":"SHA256:abc","name":null,
              "vault_id":"personal","created_at":"2026-01-01T00:00:00Z",
              "updated_at":"2026-01-01T00:00:00Z","deleted_at":null,"clocks":{}}]
            """.utf8).write(to: dir.appending(path: "known_hosts.json"))

        let first = try core()
        #expect(try rows(try await first.entityList(kind: .knownHosts)).map { $0["id"] as? String } == ["kh1"])
        try await first.entityDelete(kind: .knownHosts, id: "kh1")
        #expect(try await core().entityList(kind: .knownHosts) == "[]")
    }

    @Test func aMasterPasswordVaultOpensOnlyWithItsPassword() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let core = try core()
        #expect(try await core.vaultStatus() == .uninitialised)
        try await core.vaultInitialise(masterPassword: "correct horse")
        try core.secretSet(key: "password:c1", value: "pw")
        core.vaultLock()
        #expect(try await core.vaultStatus() == .locked(mode: .masterPassword))
        #expect(throws: VaultError.Locked) { try core.secretGet(key: "password:c1") }

        do {
            try await core.vaultUnlock(masterPassword: "battery staple")
            Issue.record("a wrong password unlocked the vault")
        } catch VaultError.WrongKey {}

        let relaunched = try self.core()
        try await relaunched.vaultUnlock(masterPassword: "correct horse")
        #expect(try relaunched.secretGet(key: "password:c1") == "pw")
        try relaunched.secretDelete(key: "password:c1")
        #expect(try relaunched.secretGet(key: "password:c1") == nil)
    }

    @Test func aKeychainVaultOpensWithoutAPassword() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let core = try core()
        try await core.vaultInitialise(masterPassword: nil)
        #expect(try await core.vaultStatus() == .unlocked(mode: .keychain))
        try core.secretSet(key: "key:k1:private", value: "pem")

        let relaunched = try self.core()
        #expect(try await relaunched.vaultStatus() == .locked(mode: .keychain))
        try await relaunched.vaultUnlock(masterPassword: nil)
        #expect(try relaunched.secretGet(key: "key:k1:private") == "pem")
    }
}
