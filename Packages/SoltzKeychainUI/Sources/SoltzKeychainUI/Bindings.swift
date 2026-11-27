// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

// shortcut: SDK 27 makes `@State` a macro whose plugin (SwiftUIMacros) ships only with Xcode; this
// alias reaches the property wrapper directly, as SoltzHostsUI does. Go back to `@State` once builds have Xcode.
typealias ViewState<Value> = SwiftUI.State<Value>

extension Binding where Value == String? {
    /// nil reads as ""; "" writes nil.
    var orEmpty: Binding<String> {
        Binding<String>(get: { wrappedValue ?? "" }, set: { wrappedValue = $0.isEmpty ? nil : $0 })
    }

    /// nil reads as ""; any write is kept, so a secret cleared on purpose is handed back as "".
    var typed: Binding<String> {
        Binding<String>(get: { wrappedValue ?? "" }, set: { wrappedValue = $0 })
    }
}

extension Binding {
    /// A numeric field: digits only, clamped to `range`, empty is nil.
    func digits(_ range: ClosedRange<UInt32>) -> Binding<String> where Value == UInt32? {
        Binding<String>(get: { wrappedValue.map(String.init) ?? "" }, set: {
            let digits = $0.filter { $0.isASCII && $0.isNumber }
            wrappedValue = digits.isEmpty ? nil : Swift.min(Swift.max(UInt32(digits.prefix(9)) ?? range.upperBound, range.lowerBound), range.upperBound)
        })
    }

    func isPresent<Wrapped: Sendable>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(get: { wrappedValue != nil }, set: { if !$0 { wrappedValue = nil } })
    }
}
