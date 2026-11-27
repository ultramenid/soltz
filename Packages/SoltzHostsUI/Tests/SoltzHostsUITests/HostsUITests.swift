// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import SoltzModel
@testable import SoltzHostsUI

private func host(_ id: String, _ extra: JSONObject = [:]) throws -> Connection {
    var json: JSONObject = [
        "id": .string(id), "host": .string("h-\(id)"), "port": 22, "username": "u", "tags": [],
        "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z", "clocks": [:],
    ]
    json.merge(extra) { _, new in new }
    return try Connection(json: json)
}

private func folder(_ id: String, parent: String? = nil, _ extra: JSONObject = [:]) throws -> Folder {
    var json: JSONObject = [
        "id": .string(id), "name": .string(id.uppercased()), "created_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z", "clocks": [:], "object_type": "connection",
    ]
    if let parent { json["parent_folder_id"] = .string(parent) }
    json.merge(extra) { _, new in new }
    return try Folder(json: json)
}

private func identity(_ id: String, username: String, keyID: String? = nil) throws -> Identity {
    var json: JSONObject = [
        "id": .string(id), "username": .string(username), "created_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z", "clocks": [:],
    ]
    if let keyID { json["key_id"] = .string(keyID) }
    return try Identity(json: json)
}

@Suite struct BrowserRules {
    @Test func rootShowsUnfiledAndOrphanedHostsButNeverTombstones() throws {
        let folders = [try folder("a"), try folder("b", parent: "a"), try folder("c", parent: "gone"),
                       try folder("dead", ["deleted_at": "2026-02-01T00:00:00Z"]),
                       try folder("keys", ["object_type": "keychain"])]
        let hosts = [try host("1"), try host("2", ["folder_id": "a"]), try host("3", ["folder_id": "nowhere"]),
                     try host("4", ["deleted_at": "2026-02-01T00:00:00Z"]), try host("5", ["folder_id": "dead"])]
        let root = HostRules.level(connections: hosts, folders: folders, folderID: nil, query: "", tags: [], sort: .newest)
        #expect(Set(root.hosts.map(\.id)) == ["1", "3", "5"])
        #expect(root.folders.map(\.id) == ["a", "c"])
        let inA = HostRules.level(connections: hosts, folders: folders, folderID: "a", query: "", tags: [], sort: .newest)
        #expect(inA.hosts.map(\.id) == ["2"])
        #expect(inA.folders.map(\.id) == ["b"])
        #expect(inA.path.map(\.id) == ["a"])
    }

    @Test func pinnedGetsItsOwnSectionUnlessSearching() throws {
        let hosts = [try host("1", ["pinned": true]), try host("2")]
        let level = HostRules.level(connections: hosts, folders: [], folderID: nil, query: "", tags: [], sort: .newest)
        #expect(level.pinned.map(\.id) == ["1"])
        #expect(level.hosts.map(\.id) == ["2"])
        let searching = HostRules.level(connections: hosts, folders: [], folderID: nil, query: "h-", tags: [], sort: .nameAscending)
        #expect(searching.pinned.isEmpty)
        #expect(searching.hosts.map(\.id) == ["1", "2"])
    }

    @Test func searchFoldsCaseAndAccentsAndCoversTags() throws {
        let c = try host("1", ["name": "Zürich Box", "username": "Admin", "tags": ["prod"]])
        #expect(HostRules.matches(c, query: "zurich"))
        #expect(HostRules.matches(c, query: "ADMIN"))
        #expect(HostRules.matches(c, query: "PROD"))
        #expect(HostRules.matches(c, query: "  "))
        #expect(!HostRules.matches(c, query: "staging"))
    }

    @Test func tagFilterMatchesAnySelectedTag() throws {
        let hosts = [try host("1", ["tags": ["a"]]), try host("2", ["tags": ["b"]]), try host("3")]
        let level = HostRules.level(connections: hosts, folders: [], folderID: nil, query: "", tags: ["a", "b"], sort: .oldest)
        #expect(level.hosts.map(\.id) == ["1", "2"])
        #expect(HostRules.tags(hosts) == ["a", "b"])
    }

    @Test func sortModesFollowUpstream() throws {
        let a = try host("a", ["name": "web 10", "created_at": "2026-01-02T00:00:00Z"])
        let b = try host("b", ["name": "web 9", "created_at": "2026-01-01T00:00:00Z"])
        let c = try host("c", ["host": "alpha", "created_at": "2026-01-03T00:00:00Z"])  // no name: sorts by host
        #expect(HostRules.sorted([a, b, c], by: .nameAscending).map(\.id) == ["c", "b", "a"])
        #expect(HostRules.sorted([a, b, c], by: .nameDescending).map(\.id) == ["a", "b", "c"])
        #expect(HostRules.sorted([a, b, c], by: .newest).map(\.id) == ["c", "a", "b"])
        #expect(HostRules.sorted([a, b, c], by: .oldest).map(\.id) == ["b", "a", "c"])
    }

    @Test func breadcrumbSurvivesParentCycles() throws {
        let folders = [try folder("x", parent: "y"), try folder("y", parent: "x")]
        let path = HostRules.path(to: "x", in: HostRules.index(folders))
        #expect(path.map(\.id) == ["y", "x"])
        #expect(HostRules.path(to: "missing", in: HostRules.index(folders)).isEmpty)
    }

    @Test func folderCountsAndParentChoicesCoverTheSubtree() throws {
        let folders = [try folder("a"), try folder("b", parent: "a"), try folder("c"),
                       try folder("t", ["vault_id": "team-1"])]
        let hosts = [try host("1", ["folder_id": "a"]), try host("2", ["folder_id": "b"]),
                     try host("3", ["folder_id": "b", "deleted_at": "2026-02-01T00:00:00Z"])]
        #expect(HostRules.hostCount(in: "a", connections: hosts, folders: folders) == 2)
        #expect(HostRules.hostCount(in: "c", connections: hosts, folders: folders) == 0)
        let choices = HostRules.parentChoices(for: folders[0], vaultID: "personal", folders: folders)
        #expect(choices.map(\.id) == ["c"])
        #expect(HostRules.folderChoices(folders, vaultID: "personal").map(\.label) == ["A", "A / B", "C"])
    }

    @Test func newHostStartsLikeUpstreamAndWritesEveryKey() throws {
        let team = try folder("f", ["vault_id": "team-1"])
        let c = HostRules.newConnection(type: .ssh, in: team, id: "n", now: "2026-03-01T00:00:00.000Z")
        #expect(c.port == 22 && c.username == "root" && c.folderID == "f" && c.vaultID == "team-1")
        let json = try c.json()
        #expect(json["auth_type"] == "password" && json["jump_hosts"] == [] && json["created_at"] == "2026-03-01T00:00:00.000Z")
        let ftp = HostRules.newConnection(type: .ftp)
        #expect(ftp.port == 21 && ftp.username == "" && ftp.vaultID == "personal" && ftp.folderID == nil)
    }

    @Test func duplicateNamesTheCopyAndKeepsUnknownFields() throws {
        let original = try host("1", ["name": "db", "last_used_at": "2026-02-01T00:00:00Z", "future": 7])
        let copy = HostRules.duplicate(original, id: "2", now: "2026-03-01T00:00:00.000Z")
        #expect(copy.id == "2" && copy.name == "db (copy)" && copy.lastUsedAt == nil && copy.clocks.isEmpty)
        #expect(copy.createdAt == "2026-03-01T00:00:00.000Z")
        #expect(try copy.json()["future"] == 7)
        #expect(HostRules.duplicate(try host("3")).name == nil)
    }

    @Test func folderEditorRenamesInPlaceOrCreates() throws {
        let existing = try folder("a", ["color": "#f00", "future": true])
        let renamed = try #require(HostRules.savedFolder(existing, name: "  Prod ", parentID: "p", vaultID: "personal"))
        #expect(renamed.name == "Prod" && renamed.parentFolderID == "p" && renamed.color == "#f00")
        #expect(try renamed.json()["future"] == true)
        let created = try #require(HostRules.savedFolder(nil, name: "New", parentID: "p", vaultID: "team-1", id: "n"))
        #expect(created.id == "n" && created.vaultID == "team-1" && created.parentFolderID == "p" && created.objectType == .connection)
        #expect(HostRules.savedFolder(existing, name: "   ", parentID: nil, vaultID: "personal") == nil)
    }
}

@Suite struct EditorRules {
    @Test func switchingTypeSwapsDefaultUsernameAndPort() throws {
        var form = HostForm(HostRules.newConnection(type: .ssh), isNew: true)
        form.type = .ftp
        #expect(form.connection.username == "" && form.connection.port == 21)
        form.connection.port = 2121
        form.type = .web
        #expect(form.connection.port == 2121)
        form.webSecure = false
        #expect(form.connection.port == 2121)
        form.connection.port = 443
        form.webSecure = false
        #expect(form.connection.port == 80)
        form.type = .webdav
        form.type = .ssh
        #expect(form.connection.port == 22 && form.connection.username == "root")
    }

    @Test func sshHostFieldSplitsUserHostPort() throws {
        var form = HostForm(HostRules.newConnection(), isNew: true)
        form.host = "admin@10.0.0.1:2200"
        #expect(form.connection.host == "10.0.0.1" && form.connection.username == "admin" && form.connection.port == 2200)
        form.connection.identityID = "i"
        form.host = "other@10.0.0.2"
        #expect(form.connection.username == "admin" && form.connection.host == "10.0.0.2")
        form.type = .ftp
        form.host = "x@y"
        #expect(form.connection.host == "x@y")
    }

    @Test func webdavURLsAreCheckedAndNormalised() {
        let target = HostForm.parseWebdavURL(" https://Cloud.Example.com ")
        #expect(target == WebdavTarget(url: "https://cloud.example.com/", host: "cloud.example.com", port: 443, secure: true))
        #expect(HostForm.parseWebdavURL("http://nas:8080/dav")?.url == "http://nas:8080/dav/")
        #expect(HostForm.parseWebdavURL("http://nas:80/dav/")?.url == "http://nas/dav/")
        for bad in ["ftp://nas/", "https://me:pw@nas/", "https://nas/?x=1", "https://nas/#a", "nas/dav", "https://"] {
            #expect(HostForm.parseWebdavURL(bad) == nil, "\(bad)")
        }
    }

    @Test func requiredFieldPerType() throws {
        var form = HostForm(HostRules.newConnection(), isNew: true)
        #expect(form.missingRequired != nil)
        form.host = "example.com"
        #expect(form.missingRequired == nil)
        form.type = .serial
        #expect(form.missingRequired != nil)
        form.connection.serialPort = "/dev/cu.usb"
        #expect(form.missingRequired == nil)
        form.type = .webdav
        form.webdavURL = "nope"
        #expect(form.missingRequired != nil)
        form.webdavURL = "https://dav.example.com"
        #expect(form.missingRequired == nil)
    }

    @Test func sshAuthFollowsIdentityOrThePasswordKeySwitch() throws {
        let ids = [try identity("i", username: "deploy", keyID: "k")]
        var form = HostForm(try host("1", ["key_id": "k2"]), isNew: false)
        form.connection.identityID = "i"
        let (viaIdentity, _) = form.finalized(identities: ids)
        #expect(viaIdentity.username == "deploy" && viaIdentity.authType == .key && viaIdentity.keyID == nil)

        form = HostForm(try host("1"), isNew: false)
        #expect(!form.useKey)
        form.useKey = true
        #expect(form.missingRequired == "Choose a key file.")
        form.keyID = "k"
        #expect(form.missingRequired == nil && form.finalized(identities: []).0.authType == .key)

        form = HostForm(try host("1"), isNew: false)
        form.password = "pw"
        form.useKey = true
        form.privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let (chosen, secrets) = form.finalized(identities: [])
        #expect(chosen.authType == .key && secrets.privateKey != nil && secrets.password == nil, "a key login saves no password")

        var stored = HostForm(try host("1", ["auth_type": "key"]), isNew: false)
        #expect(stored.useKey && stored.missingRequired == nil)
        let untouched = stored.finalized(identities: [])
        #expect(untouched.0.authType == .key && untouched.1 == HostSecrets())
        stored.privateKey = "another key"
        #expect(stored.finalized(identities: []).1.passphrase == "", "a new key file drops the old passphrase")
        stored.useKey = false
        stored.password = "pw"
        let (toPassword, cleared) = stored.finalized(identities: [])
        #expect(toPassword.authType == .password && cleared == HostSecrets(password: "pw", privateKey: "", passphrase: ""),
                "switching to Password removes the stored key")
    }

    @Test func savingResetsFieldsTheTypeDoesNotUse() throws {
        let rich: JSONObject = [
            "jump_hosts": [["id": "j", "connection_id": "x"]], "env_vars": [["id": "e", "key": "A", "value": "1"]],
            "agent_forwarding": true, "pre_command": "echo hi", "proxy": ["mode": "socks5", "host": "p"],
            "ftp_secure": true, "serial_port": "/dev/cu.old",
        ]
        var serial = HostForm(try host("1", rich), isNew: false)
        serial.type = .serial
        serial.connection.serialPort = " /dev/cu.usb "
        let (s, _) = serial.finalized(identities: [])
        #expect(s.host == "" && s.port == 0 && s.serialPort == "/dev/cu.usb" && s.serialBaud == 115_200)
        #expect(s.serialParity == SerialParity.none && s.serialAutoReconnect == true)
        #expect(s.jumpHosts.isEmpty && s.proxy == nil && !s.agentForwarding && s.preCommand == "echo hi" && !s.ftpSecure)

        var ftp = HostForm(try host("1", rich), isNew: false)
        ftp.type = .ftp
        let (f, _) = ftp.finalized(identities: [])
        #expect(f.ftpSecure && f.serialPort == nil && f.envVars.isEmpty && f.preCommand == nil && f.authType == .password)

        var dav = HostForm(try host("1", rich), isNew: false)
        dav.type = .webdav
        dav.webdavURL = "https://dav.example.com:8443/files"
        dav.proxyPassword = "pp"
        let (d, ds) = dav.finalized(identities: [])
        #expect(d.host == "dav.example.com" && d.port == 8443 && d.webdavURL == "https://dav.example.com:8443/files/")
        #expect(d.proxy?.host == "p" && ds.proxyPassword == "pp" && !d.ftpSecure)
    }

    @Test func editingKeepsUnknownFieldsAndUntouchedKeys() throws {
        let original = try host("1", [
            "future_field": "x", "proxy": ["mode": "http", "host": " p ", "future": 1],
            "env_vars": [["id": "e", "key": "A", "value": "1", "secret": true]],
        ])
        var form = HostForm(original, isNew: false)
        form.connection.name = "  Renamed  "
        form.tagsText = "b, a, b, "
        form.connection.envVars[0].value = "2"
        let (saved, _) = form.finalized(identities: [])
        let json = try saved.json()
        #expect(json["future_field"] == "x")
        #expect(json["name"] == "Renamed" && json["tags"] == ["b", "a"])
        #expect(json["proxy"]?["future"] == 1 && json["proxy"]?["host"] == "p")
        #expect(json["env_vars"]?.array?.first?["secret"] == true && json["env_vars"]?.array?.first?["value"] == "2")
        #expect(json["port"] == 22 && json["auth_type"] == nil)
    }

    @Test func knockSequenceIsWrittenOnlyWhenEditedAndValid() throws {
        var form = HostForm(try host("1"), isNew: false)
        #expect(form.editedKnockSequence == nil)
        #expect(form.finalized(identities: []).0.portKnock == nil)
        form.knock.enabled = true
        #expect(form.knockIssues(enabled: true) == [.empty])
        form.knockSteps = [KnockStep(port: 7000), KnockStep(port: 8000, proto: .udp)]
        #expect(form.editedKnockSequence == "7000/tcp,8000/udp")
        form.proxyMode = .socks5
        #expect(form.knockIssues(enabled: true) == [.udpProxy])
        form.proxyMode = .system
        #expect(form.knockIssues(enabled: true) == [.udpSystem])
        form.knockSteps.append(KnockStep())
        #expect(form.knockIssues(enabled: true).first == .port && form.editedKnockSequence == nil)
        form.knockSteps = []
        #expect(form.editedKnockSequence == nil)
        form.knock.enabled = false
        #expect(form.editedKnockSequence == "")
        let (saved, secrets) = form.finalized(identities: [])
        // Never stored and now off with no ports: dropped, as upstream does; the cleared sequence still goes out.
        #expect(saved.portKnock == nil && secrets.knockSequence == "")
    }

    @Test func numericFieldsClampAndTagsDedupe() {
        #expect(clampedDigits("abc", 1...UInt16(65535)) == nil)
        #expect(clampedDigits("7x0000", 1...UInt16(65535)) == 65535)
        #expect(clampedDigits("0", 1...UInt16(65535)) == 1)
        #expect(clampedDigits(String(repeating: "9", count: 40), 0...UInt64(99_999)) == 99_999)
        #expect(HostForm.parseTags(" web ,db,,web") == ["web", "db"])
    }
}
