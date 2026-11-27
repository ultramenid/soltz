// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

// shortcut: SDK 27 makes `@State` a macro whose plugin (SwiftUIMacros) ships only with Xcode; this
// alias reaches the property wrapper directly, as SoltzHostsUI does. Go back to `@State` once builds have Xcode.
typealias ViewState<Value> = SwiftUI.State<Value>

extension Binding {
    func isPresent<Wrapped: Sendable>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(get: { wrappedValue != nil }, set: { if !$0 { wrappedValue = nil } })
    }
}
