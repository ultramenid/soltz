// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI

/// `UserDefaults` keys of the settings: the appearance and the terminal font, which the main window applies live.
enum SettingsKey {
    static let appearance = "appearance"
    static let fontFamily = "terminalFontFamily"
    static let fontSize = "terminalFontSize"
    static let lineHeight = "terminalLineHeight"
    /// The main window's frame from before it filled the screen (`AppDelegate.unfilledFrame`).
    static let unfilledFrame = "windowUnfilledFrame"
}

/// Light, dark, or as the system is. One setting for the whole app (`NSApp.appearance`, set in `ContentView`), so
/// Home, the terminals and their palette, the file panes, popups, alerts and menus always change together.
enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }
    var title: String { rawValue.capitalized }
    /// nil follows the system.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

struct SettingsView: View {
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceSetting.system
    @AppStorage(SettingsKey.fontFamily) private var fontFamily = ""
    @AppStorage(SettingsKey.fontSize) private var fontSize = Theme.terminalSize
    @AppStorage(SettingsKey.lineHeight) private var lineHeight = Theme.terminalLineHeight
    @AppStorage(Updates.automatic) private var checksForUpdates = true
    @ViewState private var families: [String] = []

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppearanceSetting.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Terminal") {
                Picker("Font", selection: $fontFamily) {
                    Text("Default").tag("")
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Size") {
                    Stepper(value: $fontSize, in: 8...36, step: 1) {
                        Text("\(Int(fontSize)) pt").monospacedDigit()
                    }
                }
                LabeledContent("Line Height") {
                    Slider(value: $lineHeight, in: 1...2, step: 0.05) {
                        Text("Line Height")
                    } minimumValueLabel: {
                        Text("1×")
                    } maximumValueLabel: {
                        Text("2×")
                    }
                    .labelsHidden()
                    Text(lineHeight, format: .number.precision(.fractionLength(2))).monospacedDigit()
                }
            }
            Section("Updates") {
                Toggle("Check Automatically", isOn: $checksForUpdates)
                LabeledContent("Version", value: Updates.current)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .task { families = Self.monospacedFamilies(including: fontFamily) }
    }

    /// Installed fixed-pitch families, plus the saved one even if it is not (or no longer) installed.
    static func monospacedFamilies(including saved: String) -> [String] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let fixed = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName }).sorted()
        return saved.isEmpty || fixed.contains(saved) ? fixed : [saved] + fixed
    }
}
