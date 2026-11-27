// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

// shortcut: SDK 27 makes `@State` a macro whose plugin (SwiftUIMacros) ships only with Xcode; this
// alias reaches the property wrapper directly, as the app does. Go back to `@State` once builds have Xcode.
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

extension Binding where Value == Bool {
    var inverted: Binding<Bool> {
        Binding<Bool>(get: { !wrappedValue }, set: { wrappedValue = !$0 })
    }
}

extension Binding where Value == Set<String> {
    func contains(_ element: String) -> Binding<Bool> {
        Binding<Bool>(get: { wrappedValue.contains(element) }, set: {
            if $0 { wrappedValue.insert(element) } else { wrappedValue.remove(element) }
        })
    }
}

extension Binding {
    /// A numeric field: digits only, clamped to `range`, empty is nil.
    func digits<T: FixedWidthInteger & UnsignedInteger & Sendable>(_ range: ClosedRange<T>) -> Binding<String> where Value == T? {
        Binding<String>(get: { wrappedValue.map(String.init) ?? "" }, set: { wrappedValue = clampedDigits($0, range) })
    }

    func or<T: Sendable>(_ fallback: T) -> Binding<T> where Value == T? {
        Binding<T>(get: { wrappedValue ?? fallback }, set: { wrappedValue = $0 })
    }

    func isPresent<Wrapped: Sendable>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(get: { wrappedValue != nil }, set: { if !$0 { wrappedValue = nil } })
    }
}

/// The digits typed, clamped to `range`; nil when there are none.
func clampedDigits<T: FixedWidthInteger & UnsignedInteger>(_ text: String, _ range: ClosedRange<T>) -> T? {
    let digits = text.filter { $0.isASCII && $0.isNumber }
    guard !digits.isEmpty else { return nil }
    let value = UInt64(digits.prefix(18)) ?? .max
    return T(min(max(value, UInt64(range.lowerBound)), UInt64(range.upperBound)))
}
