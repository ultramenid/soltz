// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SoltzModel

/// Editor state for one key: the record plus the key material typed beside it.
/// Rules from upstream `KeyForm.tsx` and `useDerivedPublicKey.ts`.
struct KeyForm {
    /// The record being edited. Editing mutates it in place, so unknown JSON fields survive.
    var key: SshKey
    let isNew: Bool
    var tagsText: String
    /// Typed this session; nil means untouched (an existing key's stored half is kept).
    var privateKey: String? { didSet { derivePublicKey() } }
    var passphrase: String?
    /// Typed or derived this session; nil means untouched, "" clears the stored one.
    private(set) var publicKey: String?
    /// The public half was filled from the private one, so a new private half refills it.
    private var publicKeyDerived = false

    init(_ key: SshKey, isNew: Bool) {
        self.key = key
        self.isNew = isNew
        tagsText = key.tags.joined(separator: ", ")
    }

    /// What the user typed in the public key field; it is theirs from then on.
    mutating func setPublicKey(_ text: String) {
        publicKey = text
        publicKeyDerived = false
    }

    /// Generated material lands in the import fields, as in upstream. `passphrase` is nil unless
    /// the user chose to save it.
    mutating func apply(_ generated: GeneratedKey, passphrase: String?) {
        privateKey = generated.privateKey
        setPublicKey(generated.publicKey)
        self.passphrase = passphrase
    }

    /// Upstream fills an untouched public field once the private half is a complete key.
    private mutating func derivePublicKey() {
        guard publicKey == nil || publicKeyDerived else { return }
        publicKey = privateKey.flatMap(KeyText.publicKey(fromPrivate:))
        publicKeyDerived = publicKey != nil
    }

    var info: KeyInfo { KeyText.info(privateKey: privateKey ?? "", publicKey: publicKey ?? "") }

    /// Upstream `canSave`: a new key needs its private half, a replaced one may not be blank, and a
    /// public half that is not a key never saves.
    var missingRequired: String? {
        if (isNew || privateKey != nil), KeychainRules.nonEmpty(privateKey) == nil { return "Paste or choose a private key." }
        if let publicKey, KeyText.isPublicKeyInvalid(publicKey) { return "The public key is not an SSH public key." }
        return nil
    }

    /// The record and secrets to hand back. A key left unlabelled is named after its type and today.
    func finalized(now: Date = .now) -> (SshKey, KeySecrets) {
        var k = key
        if privateKey != nil { k.keyType = info.type }
        k.name = KeychainRules.nonEmpty(k.name) ?? KeychainRules.defaultKeyName(type: k.keyType, date: now)
        k.tags = KeychainRules.parseTags(tagsText)
        let secrets = KeySecrets(privateKey: privateKey, publicKey: publicKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                                 passphrase: passphrase)
        return (k, secrets)
    }
}

/// The identity's SSH key choice (upstream `KeySelector`, where "__inline__" is `.newKey`).
enum KeyChoice: Hashable {
    case none, newKey, key(String)
}

/// Editor state for one identity. Rules from upstream `IdentityForm.tsx` and `keychainForm.ts`.
struct IdentityForm {
    /// The record being edited. Editing mutates it in place, so unknown JSON fields survive.
    var identity: Identity
    let isNew: Bool
    var tagsText: String
    var password: String?
    /// Picking another key drops inline key material typed so far, as upstream does.
    var keyChoice: KeyChoice { didSet { newKey = Self.blankKey(identity) } }
    /// The key created with the identity when `keyChoice` is `.newKey`.
    var newKey: KeyForm

    init(_ identity: Identity, isNew: Bool) {
        self.identity = identity
        self.isNew = isNew
        tagsText = identity.tags.joined(separator: ", ")
        keyChoice = identity.keyID.map(KeyChoice.key) ?? .none
        newKey = Self.blankKey(identity)
    }

    private static func blankKey(_ identity: Identity) -> KeyForm {
        KeyForm(KeychainRules.newKey(vaultID: identity.vaultID), isNew: true)
    }

    /// Upstream `canSave`: a username, and a private key when one is made inline.
    var missingRequired: String? {
        if identity.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a username." }
        return keyChoice == .newKey ? newKey.missingRequired : nil
    }

    /// The identity, its password and, for `.newKey`, the key to save first (in the identity's vault).
    func finalized(now: Date = .now) -> (Identity, IdentitySecrets, newKey: (SshKey, KeySecrets)?) {
        var i = identity
        i.name = KeychainRules.nonEmpty(i.name)
        i.tags = KeychainRules.parseTags(tagsText)
        var created: (SshKey, KeySecrets)?
        switch keyChoice {
        case .none: i.keyID = nil
        case .key(let id): i.keyID = id
        case .newKey:
            created = newKey.finalized(now: now)
            i.keyID = created?.0.id
        }
        return (i, IdentitySecrets(password: password), created)
    }
}

enum KeyAlgorithm: String, CaseIterable {
    case ed25519, ecdsa, rsa

    var title: String { rawValue.uppercased() }
}

/// Upstream `KeyGenFields` state and defaults.
struct KeyGenForm {
    static let curves = ["256", "384", "521"]
    static let rsaSizes: [UInt32] = [2048, 4096]
    static let ciphers = [("aes256-ctr", "AES-256-CTR"), ("aes256-gcm", "AES-256-GCM")]
    static let defaultRounds: UInt32 = 100

    var algorithm = KeyAlgorithm.ed25519
    var curve = "256"
    var bits: UInt32 = 4096
    var passphrase = ""
    var savePassphrase = true
    var cipher = "aes256-ctr"
    /// Empty in the field means the default.
    var rounds: UInt32?

    var options: KeyGenOptions {
        let passphrase = passphrase.isEmpty ? nil : passphrase
        return KeyGenOptions(
            keyType: algorithm.rawValue,
            curve: algorithm == .ecdsa ? curve : nil,
            bits: algorithm == .rsa ? bits : nil,
            passphrase: passphrase,
            cipher: passphrase == nil ? nil : cipher,
            rounds: passphrase == nil ? nil : rounds ?? Self.defaultRounds
        )
    }

    /// What is stored with the key: the passphrase, only when the user keeps "Save Passphrase" on.
    var savedPassphrase: String? { savePassphrase && !passphrase.isEmpty ? passphrase : nil }
}
