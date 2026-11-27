// SPDX-License-Identifier: AGPL-3.0-only
import SoltzModel

/// What a key form hands back besides the record. These live in the secret store, never in the
/// SshKey JSON (upstream slots `key:<id>:private`, `key:<id>:public`, `key:<id>:passphrase`).
/// `nil` leaves the stored value as it is; an empty string clears it.
public struct KeySecrets: Equatable, Sendable {
    public var privateKey: String?
    /// Not secret, but upstream keeps it in the secret store beside the private half.
    public var publicKey: String?
    public var passphrase: String?
    /// Set on a duplicate: copy every secret stored for this key id to the new record
    /// (upstream `copyObjectSecrets`).
    public var copyFrom: String?

    public init(privateKey: String? = nil, publicKey: String? = nil, passphrase: String? = nil, copyFrom: String? = nil) {
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.passphrase = passphrase
        self.copyFrom = copyFrom
    }
}

/// The identity's password (upstream slot `identity:<id>:password`). Same `nil`/`""` rule as `KeySecrets`.
public struct IdentitySecrets: Equatable, Sendable {
    public var password: String?
    /// Set on a duplicate: copy the password stored for this identity id.
    public var copyFrom: String?

    public init(password: String? = nil, copyFrom: String? = nil) {
        self.password = password
        self.copyFrom = copyFrom
    }
}

/// The arguments of Rust `commands::keygen::generate_ssh_keypair`, already narrowed the way
/// Upstream `KeyGenFields` sends them: options that do not apply to the type are nil.
public struct KeyGenOptions: Equatable, Sendable {
    /// "ed25519", "ecdsa" or "rsa".
    public var keyType: String
    /// "256", "384" or "521"; ECDSA only.
    public var curve: String?
    /// 2048 or 4096; RSA only.
    public var bits: UInt32?
    /// nil writes the private key unencrypted.
    public var passphrase: String?
    /// "aes256-ctr" or "aes256-gcm"; only with a passphrase.
    public var cipher: String?
    /// bcrypt-pbkdf rounds; only with a passphrase.
    public var rounds: UInt32?

    public init(keyType: String, curve: String? = nil, bits: UInt32? = nil, passphrase: String? = nil,
                cipher: String? = nil, rounds: UInt32? = nil) {
        self.keyType = keyType
        self.curve = curve
        self.bits = bits
        self.passphrase = passphrase
        self.cipher = cipher
        self.rounds = rounds
    }
}

/// `GeneratedKeyPair` from the same command, minus `key_type_label`: the type is read back from the key.
public struct GeneratedKey: Sendable {
    /// OpenSSH PEM, encrypted when a passphrase was given.
    public var privateKey: String
    /// One `type base64` line.
    public var publicKey: String

    public init(privateKey: String, publicKey: String) {
        self.privateKey = privateKey
        self.publicKey = publicKey
    }
}

/// Key work that needs the Rust core or the secret store; the app implements it.
public struct KeyOperations: Sendable {
    /// Rust `generate_ssh_keypair`.
    public var generate: @Sendable (KeyGenOptions) async throws -> GeneratedKey
    /// Upstream `ensurePublicKey`: the stored `key:<id>:public`, else derived from the stored private
    /// half and passphrase (Rust `ssh_public_key_from_private`) and stored. nil when neither exists.
    public var publicKey: @Sendable (SshKey) async throws -> String?
    /// The stored `key:<id>:private`, read only when the user exports it. nil when none is stored.
    public var privateKey: @Sendable (SshKey) async throws -> String?

    public init(
        generate: @escaping @Sendable (KeyGenOptions) async throws -> GeneratedKey,
        publicKey: @escaping @Sendable (SshKey) async throws -> String?,
        privateKey: @escaping @Sendable (SshKey) async throws -> String?
    ) {
        self.generate = generate
        self.publicKey = publicKey
        self.privateKey = privateKey
    }
}
