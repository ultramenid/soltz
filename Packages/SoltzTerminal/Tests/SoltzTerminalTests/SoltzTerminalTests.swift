// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import GhosttyTerminal
@testable import SoltzTerminal
import Testing

private func lines(family: String? = nil, size: Double = 13, lineHeight: Double = 1) -> [String] {
    SoltzTerminalModel.configuration(fontFamily: family, fontSize: size, lineHeight: lineHeight)
        .rendered.split(separator: "\n").map(String.init)
}

@Test func rendersFontSettingsAndTransparentBackground() {
    let l = lines(family: "SF Mono", size: 14, lineHeight: 1.2)
    #expect(l == ["background-opacity = 0", "clipboard-write = ask", "font-family = SF Mono", "font-size = 14", "adjust-cell-height = 20%"])
}

@Test func defaultsLeaveFontToGhostty() {
    #expect(lines() == ["background-opacity = 0", "clipboard-write = ask", "font-size = 13"])
}

@Test func untrustedFontFamilyCannotInjectConfigLines() {
    let l = lines(family: "Mono\nkeybind = a=text:x")
    #expect(!l.contains { $0.hasPrefix("keybind") })
    #expect(l.contains("font-family = Monokeybind = a=text:x")) // control chars stripped, stays one line
}

@MainActor @Test func ghosttyAcceptsTheConfigInBothAppearances() {
    let model = SoltzTerminalModel(fontFamily: "Menlo", fontSize: 12, lineHeight: 1.1, onInput: { _ in }, onResize: { _ in })
    let controller = model.state.controller
    #expect(controller.lastConfigurationIssue == nil)
    controller.setColorScheme(.light)
    #expect(controller.backgroundColor == TerminalColor(red: 0xF7, green: 0xF7, blue: 0xF7))
    controller.setColorScheme(.dark)
    #expect(controller.backgroundColor == TerminalColor(red: 0x21, green: 0x21, blue: 0x21))
    #expect(model.setFont(family: nil, size: 15, lineHeight: 1))
    #expect(controller.lastConfigurationIssue == nil)
}

/// Selected text reads clearly on its selection, in both appearances (the test above has Ghostty accept these lines):
/// the pair is the system's, and at least WCAG's 4.5:1 apart.
@MainActor @Test func selectedTextContrastsWithItsSelection() {
    func luminance(_ hex: Substring) -> Double {
        let value = Int(hex, radix: 16) ?? 0
        func linear(_ shift: Int) -> Double {
            let c = Double(value >> shift & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
    }
    let theme = SoltzTerminalModel.theme()
    for palette in [theme.light, theme.dark] {
        let l = palette.rendered.split(separator: "\n").map(String.init)
        func value(_ key: String) -> Substring? { l.last { $0.hasPrefix("\(key) = ") }?.dropFirst(key.count + 3) }
        guard let background = value("selection-background"), let text = value("selection-foreground") else {
            Issue.record("no selection colours")
            continue
        }
        let (a, b) = (luminance(background), luminance(text))
        #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5, "\(text) on \(background)")
    }
}

/// Keeps the test above honest: Ghostty does report a value it cannot parse.
@MainActor @Test func ghosttyReportsAnUnparsableValue() {
    let controller = TerminalController(configuration: TerminalConfiguration().custom("adjust-cell-height", "tall"))
    #expect(controller.lastConfigurationIssue != nil)
}
