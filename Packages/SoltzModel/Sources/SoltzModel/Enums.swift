// SPDX-License-Identifier: AGPL-3.0-only

// Open enums: any string decodes and re-encodes unchanged, so a value added by a newer
// Upstream survives. Compare against the static constants; `switch` works with them.

public struct AuthType: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let password = Self(rawValue: "password")
    public static let key = Self(rawValue: "key")
}

public struct ConnectionType: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let ssh = Self(rawValue: "ssh")
    public static let serial = Self(rawValue: "serial")
    public static let ftp = Self(rawValue: "ftp")
    public static let webdav = Self(rawValue: "webdav")
    public static let web = Self(rawValue: "web")
}

public struct ProxyMode: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let direct = Self(rawValue: "direct")
    public static let system = Self(rawValue: "system")
    public static let socks5 = Self(rawValue: "socks5")
    public static let http = Self(rawValue: "http")
    public static let https = Self(rawValue: "https")
}

/// Stored by Rust as a free string; the UI writes one of these (`src/utils/keepalive.ts`).
public struct KeepalivePreset: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let fast = Self(rawValue: "fast")
    public static let balanced = Self(rawValue: "balanced")
    public static let tolerant = Self(rawValue: "tolerant")
    public static let off = Self(rawValue: "off")
}

/// Stored by Rust as a free string; `serial/connect.rs` understands these.
public struct SerialParity: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let none = Self(rawValue: "none")
    public static let odd = Self(rawValue: "odd")
    public static let even = Self(rawValue: "even")
}

/// Stored by Rust as a free string; `serial/connect.rs` understands these.
public struct SerialFlowControl: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let none = Self(rawValue: "none")
    public static let xonXoff = Self(rawValue: "xon-xoff")
    public static let rtsCts = Self(rawValue: "rts-cts")
}

/// Stored by Rust as a free string; the values the UI filters folders by.
public struct FolderObjectType: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let connection = Self(rawValue: "connection")
    public static let keychain = Self(rawValue: "keychain")
    public static let snippet = Self(rawValue: "snippet")
    public static let portForwarding = Self(rawValue: "port_forwarding")
}
