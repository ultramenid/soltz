// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SoltzCore
import Testing

/// Key generation through the bindings; the Rust tests cover every key type and logging in.
struct KeygenTests {
    struct Pair: Decodable {
        let private_key: String
        let public_key: String
        let key_type_label: String
    }

    @Test func anEncryptedKeyDerivesItsPublicHalfOnlyWithItsPassphrase() async throws {
        let core = Core()
        let options = #"{"keyType":"ed25519","passphrase":"pp","cipher":"aes256-ctr","rounds":4}"#
        let json = try await core.generateSshKeypair(optionsJson: options)
        let pair = try JSONDecoder().decode(Pair.self, from: Data(json.utf8))
        #expect(pair.key_type_label == "ED25519")
        #expect(pair.public_key.hasPrefix("ssh-ed25519 "))

        let derived = try await core.sshPublicKeyFromPrivate(privateKey: pair.private_key, passphrase: "pp")
        #expect(derived == pair.public_key)
        await #expect {
            try await core.sshPublicKeyFromPrivate(privateKey: pair.private_key, passphrase: "wrong")
        } throws: { error in
            "\(error)" == "ENCRYPTED"
        }
    }
}
