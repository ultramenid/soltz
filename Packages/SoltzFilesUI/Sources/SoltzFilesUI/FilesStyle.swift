// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// The type and spacing of the panes and the transfers card. An app passes its own scale through
/// `.environment(\.filesStyle, …)`; the defaults suit the panes on their own.
public struct FilesStyle: Sendable {
    /// File rows and the transfers' rows.
    public var row: Font
    /// Column titles and the transfers' details.
    public var detail: Font
    /// "Transfers" and other card titles.
    public var title: Font
    public var cardRadius: CGFloat
    /// Between cards.
    public var gap: CGFloat
    /// The path and filter fields in a pane's header.
    public var fieldHeight: CGFloat
    public var fieldRadius: CGFloat
    /// How the transfers card arrives and leaves; nil does not animate.
    public var motion: Animation?

    public init(row: Font = .callout, detail: Font = .caption, title: Font = .headline, cardRadius: CGFloat = 16, gap: CGFloat = 10,
                fieldHeight: CGFloat = 26, fieldRadius: CGFloat = 8, motion: Animation? = nil) {
        self.row = row
        self.detail = detail
        self.title = title
        self.cardRadius = cardRadius
        self.gap = gap
        self.fieldHeight = fieldHeight
        self.fieldRadius = fieldRadius
        self.motion = motion
    }

    var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: cardRadius, style: .continuous) }
}

private struct FilesStyleKey: EnvironmentKey {
    static let defaultValue = FilesStyle()
}

extension EnvironmentValues {
    public var filesStyle: FilesStyle {
        get { self[FilesStyleKey.self] }
        set { self[FilesStyleKey.self] = newValue }
    }
}
