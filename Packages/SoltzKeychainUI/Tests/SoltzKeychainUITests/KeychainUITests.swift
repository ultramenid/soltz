// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
import SoltzModel
@testable import SoltzKeychainUI

// Public halves from upstream's own keygen tests; the fingerprint is `ssh-keygen -lf` output.
private let edPublic = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINJXK8C5YXiVc+Y53pqq4crA8oj9YcD0w4OJbHHvUICa"
private let edFingerprint = "SHA256:CL+nGOjPgDQkO7Quvd+R+z+qI//vHmqnnLKUn9s45S4"
private let ecdsaPublic = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBChaQgDCcY0dKUKAj3RYO+c+t5qTqh2c9p7cZL5RCcG7t3iuprRKF6RPNhXSEi6N8EzRw6xD9YMQwY7QhYoAzdU="

private func wire(_ bytes: [UInt8]) -> [UInt8] {
    withUnsafeBytes(of: UInt32(bytes.count).bigEndian, Array.init) + bytes
}

/// An OpenSSH private key file around `publicKey`'s blob. Only the unencrypted header is real; the
/// private section is filler, so no private key material is involved.
private func openSSHKey(_ publicKey: String, cipher: String = "none") -> String {
    let blob = Array(Data(base64Encoded: String(publicKey.split(separator: " ")[1]))!)
    var bytes = Array("openssh-key-v1\0".utf8)
    bytes += wire(Array(cipher.utf8)) + wire(Array((cipher == "none" ? "none" : "bcrypt").utf8)) + wire([])
    bytes += withUnsafeBytes(of: UInt32(1).bigEndian, Array.init) + wire(blob) + wire([0, 0, 0, 0])
    let body = Data(bytes).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
    return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(body)\n-----END OPENSSH PRIVATE KEY-----\n"
}

/// A PuTTY v3 file around `publicKey`; the private lines are filler.
private func ppk(_ publicKey: String, comment: String, encryption: String = "none", mac: Bool = true) -> String {
    let parts = publicKey.split(separator: " ")
    let b64 = parts[1]
    let mid = b64.index(b64.startIndex, offsetBy: 30)
    return ["PuTTY-User-Key-File-3: \(parts[0])", "Encryption: \(encryption)", "Comment: \(comment)", "Public-Lines: 2",
            String(b64[..<mid]), String(b64[mid...]), "Private-Lines: 1", "AAAA"]
        .joined(separator: "\n") + (mac ? "\nPrivate-MAC: 00" : "")
}

private let stamp: JSONObject = ["created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z", "clocks": [:]]

private func key(_ id: String, _ extra: JSONObject = [:]) throws -> SshKey {
    try SshKey(json: stamp.merging(["id": .string(id)]) { _, new in new }.merging(extra) { _, new in new })
}

private func identity(_ id: String, username: String = "root", _ extra: JSONObject = [:]) throws -> Identity {
    try Identity(json: stamp.merging(["id": .string(id), "username": .string(username)]) { _, new in new }.merging(extra) { _, new in new })
}

private func folder(_ id: String, parent: String? = nil, _ extra: JSONObject = [:]) throws -> Folder {
    var json = stamp.merging(["id": .string(id), "name": .string(id.uppercased()), "object_type": "keychain"]) { _, new in new }
    if let parent { json["parent_folder_id"] = .string(parent) }
    return try Folder(json: json.merging(extra) { _, new in new })
}

private func host(_ id: String, _ extra: JSONObject = [:]) throws -> Connection {
    try Connection(json: stamp.merging(["id": .string(id), "host": "h", "port": 22, "username": "u", "tags": []]) { _, new in new }
        .merging(extra) { _, new in new })
}

private let deleted: JSONObject = ["deleted_at": "2026-02-01T00:00:00Z", "updated_at": "2026-02-01T00:00:00Z"]

@Suite struct KeyTextSniffing {
    @Test func pemKeysAreTypedAndCheckedForTheirFooter() {
        let rsa = KeyText.info(privateKey: "-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----")
        #expect(rsa == KeyInfo(type: "RSA", valid: true))
        #expect(KeyText.info(privateKey: "-----BEGIN EC PRIVATE KEY-----\nMHc") == KeyInfo(type: "ECDSA", valid: false, error: "Incomplete key"))
        #expect(KeyText.info(privateKey: "-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----").type == "PKCS8")
        let pkcs8 = KeyText.info(privateKey: "-----BEGIN ENCRYPTED PRIVATE KEY-----\nx\n-----END ENCRYPTED PRIVATE KEY-----")
        #expect(pkcs8.type == "PKCS8" && pkcs8.valid && pkcs8.encrypted)
        #expect(KeyText.info(privateKey: "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nx\n-----END RSA PRIVATE KEY-----").encrypted)
        #expect(KeyText.publicKey(fromPrivate: "-----BEGIN RSA PRIVATE KEY-----\nx\n-----END RSA PRIVATE KEY-----") == nil)
    }

    @Test func openSSHKeysAreReadFromTheirHeaderEvenWhenEncrypted() {
        #expect(KeyText.info(privateKey: openSSHKey(edPublic)) == KeyInfo(type: "ED25519", valid: true))
        #expect(KeyText.info(privateKey: openSSHKey(ecdsaPublic)).type == "ECDSA P-256")
        let encrypted = KeyText.info(privateKey: openSSHKey(edPublic, cipher: "aes256-ctr"))
        #expect(encrypted.type == "ED25519" && encrypted.encrypted)
        #expect(KeyText.publicKey(fromPrivate: openSSHKey(edPublic)) == edPublic)
        #expect(KeyText.publicKey(fromPrivate: openSSHKey(ecdsaPublic, cipher: "aes256-gcm@openssh.com")) == ecdsaPublic)
    }

    @Test func openSSHFallbacksFollowUpstream() {
        let unterminated = String(openSSHKey(edPublic).prefix(80))
        #expect(KeyText.info(privateKey: unterminated) == KeyInfo(type: nil, valid: false, error: "Incomplete key"))
        let garbage = "-----BEGIN OPENSSH PRIVATE KEY-----\n!!!\n-----END OPENSSH PRIVATE KEY-----"
        #expect(KeyText.info(privateKey: garbage) == KeyInfo(type: "OpenSSH", valid: true))
        #expect(KeyText.info(privateKey: garbage, publicKey: "ssh-rsa AAAA").type == "RSA")
        #expect(KeyText.publicKey(fromPrivate: garbage) == nil)
    }

    @Test func puttyKeysAreTypedAndTheirPublicHalfRead() {
        #expect(KeyText.info(privateKey: ppk(edPublic, comment: "plain")) == KeyInfo(type: "ED25519", valid: true))
        #expect(KeyText.info(privateKey: ppk(edPublic, comment: "x", encryption: "aes256-cbc")).encrypted)
        #expect(KeyText.info(privateKey: ppk(edPublic, comment: "x", mac: false)) == KeyInfo(type: nil, valid: false, error: "Incomplete key"))
        #expect(KeyText.publicKey(fromPrivate: ppk(edPublic, comment: "plain")) == edPublic + " plain")
        #expect(KeyText.publicKey(fromPrivate: ppk(edPublic, comment: "a;rm -rf ~")) == edPublic)
    }

    @Test func otherTextIsUnrecognizedAndEmptyIsFine() {
        #expect(KeyText.info(privateKey: "hello") == KeyInfo(type: nil, valid: false, error: "Unrecognized key format"))
        #expect(KeyText.info(privateKey: edPublic).error == "Unrecognized key format")
        #expect(KeyText.info(privateKey: "  \n") == KeyInfo(type: nil, valid: true))
    }

    @Test func publicKeysMustBeOneSafeLine() {
        #expect(KeyText.isValidPublicKey(edPublic))
        #expect(KeyText.isValidPublicKey("  \(edPublic) José@höst:2222 key=prod\n"))
        #expect(KeyText.isValidPublicKey("ssh-ed25519\tAAAA\tme"))
        #expect(KeyText.isValidPublicKey("sk-ssh-ed25519@openssh.com AAAA"))
        for bad in ["\(edPublic) a;b", "\(edPublic) $(id)", "\(edPublic) it's", "\(edPublic) a\nb", "\(edPublic) a\r\nb",
                    "ssh-foo AAAA", "ssh-ed25519", "ssh-ed25519 AAAA=== x", "ssh-ed25519 AA AA\u{7f}"] {
            #expect(!KeyText.isValidPublicKey(bad), "\(bad)")
        }
        #expect(!KeyText.isPublicKeyInvalid("  "))
        #expect(KeyText.isPublicKeyInvalid("nope"))
    }

    @Test func fingerprintMatchesSshKeygen() {
        #expect(KeyText.fingerprint(edPublic + " plain") == edFingerprint)
        #expect(KeyText.fingerprint("nope") == nil)
    }

    @MainActor @Test func exportedPrivateKeysAreOwnerOnlyEvenWhenReplacingAFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "soltz-keychain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "id_test")
        try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(KeyActions.write("filler\n", to: file, mode: 0o600) == nil)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try String(contentsOf: file, encoding: .utf8) == "filler\n")
    }

    @Test func filesAndExportNames() {
        #expect(KeyText.isPublicKeyFile(name: "id_ed25519.pub", text: "x"))
        #expect(KeyText.isPublicKeyFile(name: "key", text: "\n ecdsa-sha2-nistp256 AAAA"))
        #expect(!KeyText.isPublicKeyFile(name: "id_rsa", text: "-----BEGIN"))
        #expect(KeyText.fileContents("  pem\n\n") == "pem\n")
        #expect(KeyText.exportFileName(keyType: "ECDSA P-256", publicHalf: true) == "id_ecdsa.pub")
        #expect(KeyText.exportFileName(keyType: "ED25519", publicHalf: false) == "id_ed25519")
        #expect(KeyText.exportFileName(keyType: "PKCS8", publicHalf: false) == "id_key")
        #expect(KeyText.exportFileName(keyType: nil, publicHalf: true) == "id_key.pub")
    }
}

@Suite struct ListRules {
    @Test func livenessFollowsRustIsAlive() {
        #expect(KeychainRules.isLive(deletedAt: nil, updatedAt: "2026-01-01T00:00:00Z"))
        #expect(!KeychainRules.isLive(deletedAt: "2026-02-01T00:00:00Z", updatedAt: "2026-02-01T00:00:00Z"))
        #expect(KeychainRules.isLive(deletedAt: "2026-02-01T00:00:00Z", updatedAt: "2026-03-01T00:00:00Z"))
    }

    @Test func rootShowsUnfiledAndOrphanedItemsButNeverTombstones() throws {
        let folders = [try folder("a"), try folder("b", parent: "a"), try folder("hosts", ["object_type": "connection"]),
                       try folder("dead", deleted)]
        let keys = [try key("k1"), try key("k2", ["folder_id": "a"]), try key("k3", ["folder_id": "gone"]), try key("k4", deleted),
                    try key("k5", ["folder_id": "hosts"]), try key("k6", ["folder_id": "dead"]),
                    try key("k7", ["deleted_at": "2026-02-01T00:00:00Z", "updated_at": "2026-03-01T00:00:00Z"])]
        let identities = [try identity("i1", ["folder_id": "b"]), try identity("i2", deleted)]
        let root = KeychainRules.level(keys: keys, identities: identities, folders: folders, folderID: nil, query: "", tags: [], sort: .oldest)
        #expect(Set(root.keys.map(\.id)) == ["k1", "k3", "k5", "k6", "k7"])
        #expect(root.identities.isEmpty)
        #expect(root.folders.map(\.id) == ["a"])
        let inB = KeychainRules.level(keys: keys, identities: identities, folders: folders, folderID: "b", query: "", tags: [], sort: .oldest)
        #expect(inB.path.map(\.id) == ["a", "b"])
        #expect(inB.identities.map(\.id) == ["i1"])
        #expect(inB.keys.isEmpty)
    }

    @Test func pinnedComeFirstUnlessSearching() throws {
        let keys = [try key("k1", ["pinned": true, "name": "alpha"]), try key("k2", ["name": "beta"])]
        let identities = [try identity("i1", ["pinned": true]), try identity("i2")]
        let level = KeychainRules.level(keys: keys, identities: identities, folders: [], folderID: nil, query: "", tags: [], sort: .newest)
        #expect(level.pinnedKeys.map(\.id) == ["k1"] && level.keys.map(\.id) == ["k2"])
        #expect(level.pinnedIdentities.map(\.id) == ["i1"] && level.identities.map(\.id) == ["i2"])
        let searching = KeychainRules.level(keys: keys, identities: identities, folders: [], folderID: nil, query: "a", tags: [], sort: .newest)
        #expect(searching.pinnedKeys.isEmpty && searching.keys.map(\.id) == ["k1", "k2"])
    }

    @Test func searchCoversUpstreamFieldsAndTags() throws {
        let k = try key("k", ["name": "Zürich laptop", "key_type": "ED25519", "tags": ["prod"]])
        #expect(KeychainRules.matches(k, query: "zurich"))
        #expect(KeychainRules.matches(k, query: "ed25519"))
        #expect(KeychainRules.matches(k, query: "PROD"))
        #expect(!KeychainRules.matches(k, query: "rsa"))
        let i = try identity("i", username: "deploy")
        #expect(KeychainRules.matches(i, query: "DEP"))
        #expect(!KeychainRules.matches(i, query: "root"))
    }

    @Test func sortFollowsUpstreamSortByMode() throws {
        let a = try key("a", ["name": "web 10", "created_at": "2026-01-02T00:00:00Z"])
        let b = try key("b", ["name": "web 9", "created_at": "2026-01-01T00:00:00Z"])
        let c = try key("c", ["created_at": "2026-01-03T00:00:00Z"])  // no name: sorts as ""
        #expect(KeychainRules.sorted([a, b, c], by: .nameAscending).map(\.id) == ["c", "b", "a"])
        #expect(KeychainRules.sorted([a, b, c], by: .nameDescending).map(\.id) == ["a", "b", "c"])
        #expect(KeychainRules.sorted([a, b, c], by: .newest).map(\.id) == ["c", "a", "b"])
        #expect(KeychainRules.sorted([a, b, c], by: .oldest).map(\.id) == ["b", "a", "c"])
    }

    @Test func tagFilterMatchesAnySelectedTag() throws {
        let keys = [try key("k1", ["tags": ["a"]]), try key("k2"), try key("k3", ["tags": ["z"]].merging(deleted) { _, new in new })]
        let identities = [try identity("i1", ["tags": ["b"]])]
        let level = KeychainRules.level(keys: keys, identities: identities, folders: [], folderID: nil, query: "", tags: ["a", "b"], sort: .newest)
        #expect(level.keys.map(\.id) == ["k1"] && level.identities.map(\.id) == ["i1"])
        #expect(KeychainRules.tags(keys: keys, identities: identities) == ["a", "b"])
    }

    @Test func deleteSaysWhatUsesTheItem() throws {
        let hosts = [try host("h1", ["name": "web", "key_id": "k"]), try host("h2", ["key_id": "k"]),
                     try host("h3", ["key_id": "k"].merging(deleted) { _, new in new }), try host("h4", ["identity_id": "i"])]
        let identities = [try identity("i", ["name": "admin", "key_id": "k"]), try identity("j", ["key_id": "other"])]
        let usage = KeychainRules.usage(ofKey: "k", connections: hosts, identities: identities)
        #expect(usage.hosts.map(\.id) == ["h1", "h2"] && usage.identities.map(\.id) == ["i"])
        #expect(KeychainRules.deleteMessage(hosts: usage.hosts, identities: usage.identities)
            == "Used by 2 hosts (web, u@h:22) and 1 identity (admin), which will no longer sign in with it. This cannot be undone.")
        #expect(KeychainRules.hosts(usingIdentity: "i", connections: hosts).map(\.id) == ["h4"])
        #expect(KeychainRules.deleteMessage(hosts: []) == "This cannot be undone.")
        #expect(KeychainRules.names(["a", "b", "c", "d", "e"]) == "a, b, c and 2 more")
    }

    @Test func folderCountsChoicesAndDeleteMessage() throws {
        let folders = [try folder("a"), try folder("b", parent: "a"), try folder("c", parent: "b"), try folder("t", ["vault_id": "team"]),
                       try folder("h", ["object_type": "connection"])]
        let keys = [try key("k1", ["folder_id": "b"]), try key("k2", ["folder_id": "a"].merging(deleted) { _, new in new })]
        let identities = [try identity("i1", ["folder_id": "c"]), try identity("i2", ["folder_id": "t"])]
        #expect(KeychainRules.itemCount(in: "a", keys: keys, identities: identities, folders: folders) == 2)
        #expect(KeychainRules.folderDeleteMessage(itemCount: 1)
            == "This will delete the folder, its subfolders, and the 1 item inside. This cannot be undone.")
        #expect(KeychainRules.folderDeleteMessage(itemCount: 0)
            == "This will delete the folder and everything inside it. This cannot be undone.")
        #expect(KeychainRules.folderChoices(folders, vaultID: "personal").map(\.label) == ["A", "A / B", "A / B / C"])
        #expect(KeychainRules.parentChoices(for: folders[1], folders: folders).map(\.id) == ["a"])
    }

    @Test func newRecordsDecodeAndTakeTheirFoldersVault() throws {
        let team = try folder("t", ["vault_id": "team"])
        let k = KeychainRules.newKey(in: team, id: "n", now: "2026-05-01T00:00:00.000Z")
        #expect(k.vaultID == "team" && k.folderID == "t" && k.raw == nil && !k.pinned)
        #expect(KeychainRules.newKey(vaultID: "solo").vaultID == "solo")
        let i = KeychainRules.newIdentity()
        #expect(i.vaultID == "personal" && i.username.isEmpty)
        let made = try #require(KeychainRules.savedFolder(nil, name: "  Work ", parent: team, id: "f"))
        #expect(made.name == "Work" && made.objectType == .keychain && made.vaultID == "team" && made.parentFolderID == "t")
        #expect(KeychainRules.savedFolder(nil, name: " ", parent: nil) == nil)
        let renamed = try #require(KeychainRules.savedFolder(try folder("a", ["future": 1]), name: "Renamed", parent: nil))
        #expect(try renamed.json()["future"] == 1 && renamed.id == "a")
    }

    @Test func duplicateNamesTheCopyUnpinsItAndKeepsUnknownFields() throws {
        let original = try key("k", ["name": "deploy", "pinned": true, "folder_id": "a", "future": 7, "clocks": ["name": "x"]])
        let copy = KeychainRules.duplicate(original, id: "k2", now: "2026-06-01T00:00:00.000Z")
        #expect(copy.id == "k2" && copy.name == "deploy (copy)" && !copy.pinned && copy.folderID == "a")
        #expect(copy.createdAt == "2026-06-01T00:00:00.000Z" && copy.clocks.isEmpty)
        #expect(try copy.json()["future"] == 7)
        let nameless = KeychainRules.duplicate(try identity("i", ["key_id": "k"]))
        #expect(nameless.name == nil && nameless.keyID == "k")
    }

    @Test func datesFromRustAndJavaScriptParse() {
        let expected = Date(timeIntervalSince1970: 1_767_323_045)  // 2026-01-02T03:04:05Z
        #expect(KeychainRules.date("2026-01-02T03:04:05.123456789+00:00") == expected)
        #expect(KeychainRules.date("2026-01-02T03:04:05.123Z") == expected)
        #expect(KeychainRules.date("2026-01-02T03:04:05Z") == expected)
        #expect(KeychainRules.date("garbage") == nil)
    }
}

@Suite struct Forms {
    @Test func editingAKeyKeepsUnknownFieldsAndLeavesSecretsAlone() throws {
        let stored = try key("key-old", ["name": "laptop", "key_type": "ED25519", "vault_ids": [], "fingerprint_cache": "SHA256:abc"])
        var form = KeyForm(stored, isNew: false)
        form.key.name = "renamed"
        form.tagsText = "a, b, a"
        #expect(form.missingRequired == nil)
        let (saved, secrets) = form.finalized()
        #expect(secrets == KeySecrets())
        let json = try saved.json()
        #expect(json["fingerprint_cache"] == "SHA256:abc")
        #expect(json["name"] == "renamed" && json["key_type"] == "ED25519" && json["tags"] == ["a", "b"])
        #expect(json["vault_id"] == "personal" && json["vault_ids"] == nil)  // written in migrated form, as upstream saves
    }

    @Test func aNewKeyNeedsItsPrivateHalfAndNamesItself() throws {
        var form = KeyForm(KeychainRules.newKey(), isNew: true)
        #expect(form.missingRequired != nil)
        form.privateKey = openSSHKey(edPublic)
        #expect(form.publicKey == edPublic)
        #expect(form.missingRequired == nil)
        let now = Date(timeIntervalSince1970: 1_767_323_045)
        let (saved, secrets) = form.finalized(now: now)
        #expect(saved.keyType == "ED25519")
        #expect(saved.name == KeychainRules.defaultKeyName(type: "ED25519", date: now))
        #expect(secrets.privateKey == openSSHKey(edPublic) && secrets.publicKey == edPublic && secrets.passphrase == nil)
    }

    @Test func aDerivedPublicHalfFollowsThePrivateOneUntilTyped() {
        var form = KeyForm(KeychainRules.newKey(), isNew: true)
        form.privateKey = openSSHKey(edPublic)
        form.privateKey = openSSHKey(ecdsaPublic)
        #expect(form.publicKey == ecdsaPublic)
        form.setPublicKey("")
        form.privateKey = openSSHKey(edPublic)
        #expect(form.publicKey == "")
        form.setPublicKey("not a key")
        #expect(form.missingRequired == "The public key is not an SSH public key.")
    }

    @Test func anExistingKeysPrivateHalfCannotBeBlanked() throws {
        var form = KeyForm(try key("k", ["key_type": "RSA"]), isNew: false)
        form.privateKey = "  "
        #expect(form.missingRequired != nil)
        form.privateKey = nil
        form.passphrase = ""
        #expect(form.missingRequired == nil)
        #expect(form.finalized().1 == KeySecrets(passphrase: ""))
        #expect(form.finalized().0.keyType == "RSA")
    }

    @Test func generatedMaterialFillsTheImportFields() {
        var form = KeyForm(KeychainRules.newKey(), isNew: true)
        form.apply(GeneratedKey(privateKey: openSSHKey(edPublic, cipher: "aes256-ctr"), publicKey: edPublic), passphrase: nil)
        #expect(form.info.encrypted && form.publicKey == edPublic && form.passphrase == nil)
        #expect(form.finalized().1.privateKey == openSSHKey(edPublic, cipher: "aes256-ctr"))
    }

    @Test func editingAnIdentityKeepsUnknownFields() throws {
        let stored = try identity("id-gone", username: "temp", ["fido2_handle": "abc", "key_id": "k"])
        var form = IdentityForm(stored, isNew: false)
        #expect(form.keyChoice == .key("k"))
        form.identity.username = "deploy"
        form.keyChoice = .none
        let (saved, secrets, newKey) = form.finalized()
        #expect(newKey == nil && secrets == IdentitySecrets())
        let json = try saved.json()
        #expect(json["fido2_handle"] == "abc" && json["username"] == "deploy" && json["key_id"] == .null)
    }

    @Test func anIdentityNeedsAUsernameAndMayCreateItsKey() throws {
        var form = IdentityForm(KeychainRules.newIdentity(in: try folder("t", ["vault_id": "team"])), isNew: true)
        #expect(form.missingRequired == "Enter a username.")
        form.identity.username = "root"
        form.password = "pw"
        form.keyChoice = .newKey
        #expect(form.missingRequired == "Paste or choose a private key.")
        form.newKey.privateKey = openSSHKey(edPublic)
        form.newKey.key.name = "ci"
        let (saved, secrets, newKey) = form.finalized()
        let (k, keySecrets) = try #require(newKey)
        #expect(saved.keyID == k.id && k.vaultID == "team" && k.name == "ci" && k.folderID == nil)
        #expect(keySecrets.publicKey == edPublic && secrets.password == "pw")
        form.keyChoice = .key("other")
        #expect(form.newKey.privateKey == nil && form.finalized().0.keyID == "other")
    }

    @Test func generationOptionsAreNarrowedAsUpstreamSendsThem() {
        var gen = KeyGenForm()
        #expect(gen.options == KeyGenOptions(keyType: "ed25519"))
        gen.algorithm = .ecdsa
        gen.curve = "384"
        #expect(gen.options == KeyGenOptions(keyType: "ecdsa", curve: "384"))
        gen.algorithm = .rsa
        gen.passphrase = "pw"
        #expect(gen.options == KeyGenOptions(keyType: "rsa", bits: 4096, passphrase: "pw", cipher: "aes256-ctr", rounds: 100))
        gen.rounds = 16
        gen.cipher = "aes256-gcm"
        #expect(gen.options.rounds == 16 && gen.options.cipher == "aes256-gcm")
        #expect(gen.savedPassphrase == "pw")
        gen.savePassphrase = false
        #expect(gen.savedPassphrase == nil)
    }
}
