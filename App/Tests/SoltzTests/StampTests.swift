// SPDX-License-Identifier: AGPL-3.0-only
@testable import Soltz
import SoltzModel
import Testing

/// Upstream's Rust stamping, reproduced for rows the core stores exactly as given.
@MainActor struct StampTests {
    @Test func timestampsMatchChronoRFC3339() {
        let at = 1_700_000_000
        #expect(Workspace.timestamp(seconds: at, nanoseconds: 0) == "2023-11-14T22:13:20+00:00")
        #expect(Workspace.timestamp(seconds: at, nanoseconds: 120_000_000) == "2023-11-14T22:13:20.120+00:00")
        #expect(Workspace.timestamp(seconds: at, nanoseconds: 123_456_000) == "2023-11-14T22:13:20.123456+00:00")
        #expect(Workspace.timestamp(seconds: at, nanoseconds: 1) == "2023-11-14T22:13:20.000000001+00:00")
    }

    @Test func aNewHostIsSeededAndAnEditStampsOnlyWhatChanged() throws {
        let host = try Connection(json: ["id": "c1", "host": "h", "port": 22, "username": "u", "tags": [], "created_at": "",
                                         "updated_at": "", "clocks": [:],
                                         "jump_hosts": [["id": "j1", "connection_id": "c2"]]])
        let clocks = Workspace.connectionClocks
        let created = try Workspace.stamped(host, over: nil, seeded: clocks, tracked: clocks, at: "t1")
        #expect(created.createdAt == "t1" && created.updatedAt == "t1" && created.deletedAt == nil)
        #expect(created.clocks.count == 40 && Set(created.clocks.values) == ["t1"])

        var edited = created
        edited.port = 2222
        edited.pinned = true // device-local: no clock
        edited.jumpHosts[0].host = "changed" // same ids: no clock
        edited.createdAt = "forged"
        edited.deletedAt = "t0"
        let updated = try Workspace.stamped(edited, over: created, seeded: clocks, tracked: clocks, at: "t2")
        #expect(updated.clocks.filter { $0.value == "t2" }.keys.sorted() == ["port"])
        #expect(updated.updatedAt == "t2" && updated.createdAt == "t1" && updated.deletedAt == nil && updated.pinned)

        var reordered = updated
        reordered.jumpHosts = []
        #expect(try Workspace.stamped(reordered, over: updated, seeded: clocks, tracked: clocks, at: "t3").clocks["jump_hosts"] == "t3")
        #expect(try Workspace.stamped(updated, over: updated, seeded: clocks, tracked: clocks, at: "t3").updatedAt == "t2",
                "a save that changes nothing keeps updated_at")
    }

    @Test func aFolderEditStampsPinnedButAFolderIsBornWithoutIt() throws {
        let folder = try Folder(json: ["id": "f1", "name": "A", "created_at": "", "updated_at": "", "clocks": [:]])
        let created = try Workspace.stamped(folder, over: nil, seeded: Workspace.folderCreateClocks,
                                            tracked: Workspace.folderUpdateClocks, at: "t1")
        #expect(created.clocks.keys.sorted() == ["color", "icon", "name", "object_type", "parent_folder_id", "vault_id"])

        var edited = created
        edited.pinned = true
        edited.name = "B"
        let updated = try Workspace.stamped(edited, over: created, seeded: Workspace.folderCreateClocks,
                                            tracked: Workspace.folderUpdateClocks, at: "t2")
        #expect(updated.clocks.filter { $0.value == "t2" }.keys.sorted() == ["name", "pinned"])
    }
}
