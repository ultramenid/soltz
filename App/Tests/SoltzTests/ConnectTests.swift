// SPDX-License-Identifier: AGPL-3.0-only
@testable import Soltz
import SoltzModel
import Testing

/// Connect arguments that need no stored secrets (no data directory here).
@MainActor struct ConnectTests {
    func host(_ fields: JSONObject) throws -> Connection {
        try Connection(json: ["id": "c1", "host": "h", "port": 0, "username": "u", "tags": [], "created_at": "", "updated_at": "",
                              "clocks": [:]].merging(fields) { _, given in given })
    }

    @Test func argsFollowTheHostsOptions() throws {
        let workspace = Workspace()
        let args = try workspace.connectArgs(for: host([
            "keepalive_preset": "off", "persist_session": false, "shell_integration": false, "agent_forwarding": true,
            "pre_command": "echo pre", "pre_snippet_id": "s1", "proxy": ["mode": "direct"],
        ]), login: Login(username: "me", password: "pw"))
        #expect(args["port"] == 22 && args["username"] == "me" && args["password"] == "pw" && args["privateKey"] == .null)
        #expect(args["keepaliveIntervalSecs"] == 0 && args["keepaliveMax"] == 0 && args["persist"] == false)
        #expect(args["shellIntegration"] == false && args["agentForwarding"] == true)
        #expect(args["preCommand"] == .null, "a host whose pre-command names a snippet sends no inline command")
        #expect(args["autoForward"] == false)
        #expect(args["proxy"] == ["kind": "direct"] && args["jumpHosts"] == .null && args["envVars"] == .null)
        #expect(try workspace.connectArgs(for: host([:]), login: Login(username: "me"))["keepaliveIntervalSecs"] == 3)
    }

    @Test func aProxyWithoutAHostIsRefused() throws {
        #expect(throws: ConnectProblem.self) {
            try Workspace().proxySpec(for: host(["proxy": ["mode": "http", "host": "  "]]))
        }
    }

    @Test func joiningALiveSessionOnlyAttachesAndTypesNothing() {
        let args = Workspace.forAttaching(["sessionId": "soltz-new", "persist": false, "preCommand": "cd /srv", "initialCwd": "/tmp",
                                           "host": "10.0.4.11"], to: "soltz-elsewhere")
        #expect(args["sessionId"] == "soltz-elsewhere" && args["attachOnly"] == true && args["persist"] == true)
        #expect(args["preCommand"] == .null && args["initialCwd"] == .null && args["host"] == "10.0.4.11")
    }

    @Test func knockSequencesParseAsUpstreamDoes() {
        #expect(Workspace.knockSteps("7000/tcp, 8000/udp,9000") == [
            ["port": 7000, "protocol": "tcp"], ["port": 8000, "protocol": "udp"], ["port": 9000, "protocol": "tcp"],
        ])
        for bad in ["", "7000/", "0", "70000", "7000/icmp", Array(repeating: "1", count: 17).joined(separator: ",")] {
            #expect(Workspace.knockSteps(bad) == nil, "\(bad)")
        }
    }

    @Test func quickConnectFromASavedHostKeepsItsOptions() throws {
        var form = ConnectForm(try host(["jump_hosts": [["id": "j", "connection_id": "c2"]], "keepalive_preset": "fast"]))
        form.host = " other "
        form.password = "typed"
        let target = try form.target()
        #expect(target.id == "c1" && target.host == "other" && target.port == 22 && target.jumpHosts.count == 1)
        #expect(form.login(key: nil) == Login(username: "u", password: "typed"))
        #expect(try ConnectForm().target().id != "c1")
    }

    @Test func folderSubtreesIncludeEveryDescendant() {
        let parents: [(id: String, parent: String?)] = [("a", nil), ("b", "a"), ("c", "b"), ("d", nil)]
        #expect(Workspace.subtree("a", parents) == ["a", "b", "c"])
    }
}
