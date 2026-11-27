// SPDX-License-Identifier: AGPL-3.0-only

// Records whose shape the upstream frontend owns. No serde defaults or migrations apply;
// fields follow the TypeScript types.

/// A row of the `vaults` section of `settings.json`. Rows are keyed by vault id there.
public typealias Vault = Lossless<VaultFields>

/// camelCase on disk. No `clocks`: a row merges as a whole on `updatedAt`, `deletedAt` taking the later.
public struct VaultFields: LosslessFields, Identifiable {
    /// The row's key in the section, not a JSON field; `DataReader` fills it in.
    public var id = ""
    /// Empty for a team vault: the server holds its name.
    public var name: String
    public var teamID: String?
    public var updatedAt: String
    public var deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case name, teamID = "teamId", updatedAt, deletedAt
    }
}
