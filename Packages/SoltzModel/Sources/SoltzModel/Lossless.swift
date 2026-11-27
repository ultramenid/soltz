// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// The typed part of a persisted record; `Lossless` supplies the round-trip around it.
public protocol LosslessFields: Codable, Hashable, Sendable {
    /// Rust `#[serde(default)]` values for absent keys. Used to decode, never written.
    static var defaults: JSONObject { get }
    /// Upstream's load-time rewrite of legacy shapes, applied to the JSON before decoding.
    static func migrate(_ object: inout JSONObject)
}

extension LosslessFields {
    public static var defaults: JSONObject { [:] }
    public static func migrate(_ object: inout JSONObject) {}
}

/// A record that re-encodes to exactly the JSON it was read from, except for the keys whose
/// typed value changed. Unknown keys, absent-vs-null and legacy shapes survive; a changed
/// record is written in migrated form, as upstream does when it saves.
@dynamicMemberLookup
public struct Lossless<Fields: LosslessFields>: Codable, Hashable, Sendable {
    public var fields: Fields
    /// The object as read; nil for a record built in Swift.
    public private(set) var raw: JSONObject?

    public init(_ fields: Fields) {
        self.fields = fields
    }

    public init(json: JSONObject) throws {
        fields = try Self.decodeFields(json)
        raw = json
    }

    public init(from decoder: any Decoder) throws {
        try self.init(json: JSONObject(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try json().encode(to: encoder)
    }

    /// The object to write: `raw`, with only the keys whose typed value changed replaced.
    public func json() throws -> JSONObject {
        let fresh = try jsonObject(fields)
        guard var out = raw else { return fresh }
        let base = try jsonObject(Self.decodeFields(out))
        let changed = Set(fresh.keys).union(base.keys).filter { fresh[$0] != base[$0] }
        if changed.isEmpty { return out }
        Fields.migrate(&out)
        for key in changed { out[key] = fresh[key] ?? .null }
        return out
    }

    public subscript<Value>(dynamicMember keyPath: WritableKeyPath<Fields, Value>) -> Value {
        get { fields[keyPath: keyPath] }
        set { fields[keyPath: keyPath] = newValue }
    }

    static func decodeFields(_ raw: JSONObject) throws -> Fields {
        var object = raw
        Fields.migrate(&object)
        object.merge(Fields.defaults) { present, _ in present }
        return try JSONDecoder().decode(Fields.self, from: JSONEncoder().encode(object))
    }
}

extension Lossless: Identifiable where Fields: Identifiable {
    public var id: Fields.ID { fields.id }
}

/// Rust `parse_with_migration`, which `load_json_migrated` runs on every record it loads.
func migrateLegacyRecord(_ o: inout JSONObject) {
    // migrate_vault_id: `vault_ids: [...]` (or a bare string) becomes `vault_id`.
    if o["vault_id"] != nil {
        o["vault_ids"] = nil
    } else {
        let legacy: String? = switch o.removeValue(forKey: "vault_ids") {
        case .array(let ids)?: ids.first?.string
        case .string(let id)?: id
        default: nil
        }
        o["vault_id"] = .string(legacy ?? "personal")
    }
    // migrate_shell_integration: the old force-off flag folds into the tri-state.
    if o.removeValue(forKey: "shell_integration_disabled") == true, o["shell_integration"] == nil {
        o["shell_integration"] = false
    }
    // migrate_enum_fields drops values that don't parse; open enums take any string, so only non-strings go.
    for key in ["auth_type", "connection_type"] where o[key] != nil && o[key]?.string == nil {
        o[key] = nil
    }
}
