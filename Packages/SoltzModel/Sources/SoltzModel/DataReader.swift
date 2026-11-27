// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public struct ReadResult<Record: Sendable>: Sendable {
    public var records: [Record] = []
    /// One message per record that failed to decode. Upstream drops those silently.
    public var failures: [String] = []
}

/// Reads entity files from a Soltz config directory. Read-only; never opens secrets.
/// A missing file reads as empty, as in upstream. A file that is not a JSON array throws.
public struct DataReader: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func connections() throws -> ReadResult<Connection> { try read("connections.json") }
    public func identities() throws -> ReadResult<Identity> { try read("identities.json") }
    public func sshKeys() throws -> ReadResult<SshKey> { try read("ssh_keys.json") }
    public func folders() throws -> ReadResult<Folder> { try read("folders.json") }
    public func knownHosts() throws -> ReadResult<KnownHost> { try read("known_hosts.json") }

    /// The `vaults` section of `settings.json`. That file is written only once sync has run;
    /// before that, upstream keeps vaults in webview localStorage, which this cannot read.
    public func vaults() throws -> ReadResult<Vault> {
        var result = ReadResult<Vault>()
        guard let data = try contents(of: "settings.json"),
              case .object(let rows)? = try JSONDecoder().decode(JSONValue.self, from: data)["sections"]?["vaults"]?["data"]
        else { return result }
        for (id, row) in rows.sorted(by: { $0.key < $1.key }) {
            do {
                var vault = try JSONDecoder().decode(Vault.self, from: JSONEncoder().encode(row))
                vault.fields.id = id
                result.records.append(vault)
            } catch {
                result.failures.append("settings.json vaults[\(id)]: \(error)")
            }
        }
        return result
    }

    func read<Record: Decodable & Sendable>(_ file: String) throws -> ReadResult<Record> {
        var result = ReadResult<Record>()
        guard let data = try contents(of: file) else { return result }
        for (index, item) in try JSONDecoder().decode([Attempt<Record>].self, from: data).enumerated() {
            switch item.result {
            case .success(let record): result.records.append(record)
            case .failure(let error): result.failures.append("\(file)[\(index)]: \(error)")
            }
        }
        return result
    }

    func contents(of file: String) throws -> Data? {
        let url = directory.appending(path: file)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return try Data(contentsOf: url)
    }
}

/// Decodes one array element, keeping its error instead of failing the whole array.
private struct Attempt<Record: Decodable>: Decodable {
    let result: Result<Record, any Error>

    init(from decoder: any Decoder) throws {
        result = Result { try Record(from: decoder) }
    }
}
