// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Foundation

/// What can be told about pasted key text without the Rust core.
struct KeyInfo: Equatable {
    /// Display label, stored as the key's `key_type` (e.g. "ED25519", "ECDSA P-256", "PKCS8").
    var type: String?
    var valid: Bool
    var error: String?
    var encrypted = false
}

/// Key-text sniffing, ported from upstream `keyDetection.ts`, `sshPublicKey.ts` and `KeyFileDropZone.tsx`.
/// Only unencrypted file headers are read; nothing here decrypts or checks a passphrase.
enum KeyText {
    /// Upstream `PUB_TYPE_MAP`.
    static let typeLabels: [String: String] = [
        "ssh-ed25519": "ED25519", "ssh-rsa": "RSA", "ecdsa-sha2-nistp256": "ECDSA P-256",
        "ecdsa-sha2-nistp384": "ECDSA P-384", "ecdsa-sha2-nistp521": "ECDSA P-521", "ssh-dss": "DSA",
    ]

    /// PEM labels upstream recognises, plus encrypted PKCS#8, which it calls unrecognized.
    static let pemTypes: [(label: String, type: String)] = [
        ("RSA PRIVATE KEY", "RSA"), ("EC PRIVATE KEY", "ECDSA"), ("DSA PRIVATE KEY", "DSA"),
        ("PRIVATE KEY", "PKCS8"), ("ENCRYPTED PRIVATE KEY", "PKCS8"),
    ]

    static let openSSHBegin = "-----BEGIN OPENSSH PRIVATE KEY-----"
    static let openSSHEnd = "-----END OPENSSH PRIVATE KEY-----"

    /// Upstream `detectKeyInfo`, plus whether the key is passphrase-protected.
    static func info(privateKey: String, publicKey: String = "") -> KeyInfo {
        let pk = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if pk.isEmpty { return KeyInfo(type: nil, valid: true) }
        let incomplete = KeyInfo(type: nil, valid: false, error: "Incomplete key")

        for (label, type) in pemTypes where pk.hasPrefix("-----BEGIN \(label)-----") {
            let complete = pk.contains("-----END \(label)-----")
            return KeyInfo(type: type, valid: complete, error: complete ? nil : "Incomplete key",
                           encrypted: label.hasPrefix("ENCRYPTED") || pk.contains("Proc-Type: 4,ENCRYPTED"))
        }

        if let algorithm = puttyField(pk, "PuTTY-User-Key-File-") {
            guard pk.split(whereSeparator: \.isNewline).contains(where: { $0.hasPrefix("Private-MAC: ") }) else { return incomplete }
            return KeyInfo(type: typeLabels[algorithm] ?? algorithm, valid: true,
                           encrypted: (puttyField(pk, "Encryption") ?? "none") != "none")
        }

        if pk.hasPrefix(openSSHBegin) {
            guard pk.contains(openSSHEnd) else { return incomplete }
            let header = openSSHHeader(pk)
            let encrypted = header.map { $0.cipher != "none" } ?? false
            let pub = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if let label = typeLabels.first(where: { pub.hasPrefix($0.key) })?.value {
                return KeyInfo(type: label, valid: true, encrypted: encrypted)
            }
            guard let blob = header?.publicBlob, let name = blobType(blob) else {
                return KeyInfo(type: "OpenSSH", valid: true, encrypted: encrypted)
            }
            return KeyInfo(type: typeLabels[name] ?? name, valid: true, encrypted: encrypted)
        }

        return KeyInfo(type: nil, valid: false, error: "Unrecognized key format")
    }

    /// The public half of an OpenSSH or PuTTY private key, read from the file's unencrypted
    /// header, so it works without the passphrase. nil for PEM keys, as in upstream
    /// `ssh_public_key_from_private`, and for anything `isValidPublicKey` refuses.
    // shortcut: an OpenSSH key's comment sits in the private section, so the derived line has none;
    // derive through the Rust core (`ssh_public_key_from_private`) if the comment matters.
    static func publicKey(fromPrivate text: String) -> String? {
        let pk = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var line: String?
        if pk.hasPrefix(openSSHBegin), pk.contains(openSSHEnd), let blob = openSSHHeader(pk)?.publicBlob, let type = blobType(blob) {
            line = "\(type) \(Data(blob).base64EncodedString())"
        } else if let type = puttyField(pk, "PuTTY-User-Key-File-") {
            let lines = pk.split(whereSeparator: \.isNewline).map(String.init)
            guard let start = lines.firstIndex(where: { $0.hasPrefix("Public-Lines: ") }),
                  let count = Int(lines[start].dropFirst("Public-Lines: ".count).trimmingCharacters(in: .whitespaces)),
                  count > 0, start + count < lines.count else { return nil }
            let body = lines[(start + 1)...(start + count)].joined().trimmingCharacters(in: .whitespaces)
            line = "\(type) \(body)"
            if let comment = puttyField(pk, "Comment"), !comment.isEmpty, isValidPublicKey("\(type) \(body) \(comment)") {
                line = "\(type) \(body) \(comment)"
            }
        }
        return line.flatMap { isValidPublicKey($0) ? $0 : nil }
    }

    /// Upstream `isValidSshPublicKey`: one "type base64 [comment]" line, with a comment that cannot
    /// smuggle a newline or a shell metacharacter into a remote `authorized_keys` or `~/.ssh/rc`.
    static func isValidPublicKey(_ value: String) -> Bool {
        let pattern = #/(?:ssh-(?:rsa|dss|ed25519)|ecdsa-sha2-nistp(?:256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[ \t]+[A-Za-z0-9+\/]+={0,2}(?:[ \t]+[^\x00-\x20;|&$`<>()'"\\\x7f][^\x00-\x1f;|&$`<>()'"\\\x7f]*)?/#
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? pattern.matchingSemantics(.unicodeScalar).wholeMatch(in: trimmed)) != nil
    }

    /// Upstream `isPublicKeyInvalid`: empty is fine, the public half is optional.
    static func isPublicKeyInvalid(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isValidPublicKey(value)
    }

    /// The `ssh-keygen -l` fingerprint: "SHA256:" and the unpadded base64 digest of the key blob.
    static func fingerprint(_ publicKey: String) -> String? {
        guard isValidPublicKey(publicKey) else { return nil }
        let parts = publicKey.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// Upstream `KeyFileDropZone`: a `.pub` file, or text that starts like a public key, fills the
    /// public field; anything else the private one.
    static func isPublicKeyFile(name: String, text: String) -> Bool {
        let start = text.drop(while: \.isWhitespace)
        return name.hasSuffix(".pub") || ["ssh-", "ecdsa-", "sk-"].contains { start.hasPrefix($0) }
    }

    /// What an exported key file holds: OpenSSH refuses a private key without its final newline,
    /// and upstream trims key text on import.
    static func fileContents(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// `ssh-keygen`'s default file name for the key's type; `.pub` for the public half.
    static func exportFileName(keyType: String?, publicHalf: Bool) -> String {
        let word = keyType?.split(separator: " ").first?.lowercased() ?? ""
        let base = ["ed25519", "ecdsa", "rsa", "dsa"].contains(word) ? "id_\(word)" : "id_key"
        return publicHalf ? base + ".pub" : base
    }

    // MARK: Parsing

    /// The value of a PuTTY header line `name: value`. A `name` ending in "-" is the first line,
    /// `PuTTY-User-Key-File-<version>`, which must open the text.
    private static func puttyField(_ text: String, _ name: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline)
        for line in name.hasSuffix("-") ? Array(lines.prefix(1)) : lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon]
            let matches = name.hasSuffix("-")
                ? key.hasPrefix(name) && key.count > name.count && key.dropFirst(name.count).allSatisfy(\.isNumber)
                : key == name
            if matches { return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    /// `openssh-key-v1` header: cipher name, then the first public key blob, both unencrypted.
    private static func openSSHHeader(_ pk: String) -> (cipher: String, publicBlob: [UInt8])? {
        let body = pk.replacingOccurrences(of: openSSHBegin, with: "").replacingOccurrences(of: openSSHEnd, with: "")
            .filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: body) else { return nil }
        let magic = Array("openssh-key-v1\0".utf8)
        var reader = WireReader(bytes: Array(data))
        guard reader.bytes.starts(with: magic) else { return nil }
        reader.position = magic.count
        guard let cipher = reader.string(), reader.string() != nil, reader.string() != nil, reader.uint32() != nil,
              let blob = reader.string() else { return nil }
        return (String(decoding: cipher, as: UTF8.self), blob)
    }

    /// The algorithm name a public key blob starts with.
    private static func blobType(_ blob: [UInt8]) -> String? {
        var reader = WireReader(bytes: blob)
        return reader.string().map { String(decoding: $0, as: UTF8.self) }.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// RFC 4251 `uint32` and `string` reader.
private struct WireReader {
    var bytes: [UInt8]
    var position = 0

    mutating func uint32() -> Int? {
        guard position + 4 <= bytes.count else { return nil }
        defer { position += 4 }
        return bytes[position..<position + 4].reduce(0) { $0 << 8 | Int($1) }
    }

    mutating func string() -> [UInt8]? {
        guard let count = uint32(), count <= bytes.count - position else { return nil }
        defer { position += count }
        return Array(bytes[position..<position + count])
    }
}
