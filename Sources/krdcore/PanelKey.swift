import Foundation

/// What the *pixels* of a source depend on that the layout cannot see (issue #100).
///
/// A wall panel is photographed through ScreenCaptureKit, and a repaint that re-shot every panel
/// cost the reader 92 ms per page step for pictures it already had. The rule that makes a repaint
/// cheap is one key per picture: a picture is reused exactly when its `PanelKey` is unchanged. This
/// is the half of that key the geometry does not carry — the source's own shape:
///
/// - a display: its point size. A resolution change is a different picture.
/// - a window: its bounds **origin and size** and its title. A window that moved, resized or was
///   retitled shows something else; a window that only moved to *another card* (a page position)
///   is the same picture and stays cached.
///
/// Why the origin of a window and not of a display: two windows can have the same size and be
/// different pictures (different documents), and the thing that changes when the reader drags one is
/// the origin. A display's origin is its place in the desktop, which no capture reads.
///
/// The id is deliberately **not** here: it is `PanelKey`'s `source`, and keeping the stamp a pure
/// property of "what does this source look like" is what lets the key compare a display's stamp
/// against another pane's.
public struct PanelSourceStamp: Equatable, Hashable {
    /// The shape of the source, in the source's own units: points for a display, points for a
    /// window's bounds (the window server's coordinate space, top-left origin).
    public enum Kind: Equatable, Hashable {
        case display(width: Int, height: Int)
        case window(x: Double, y: Double, width: Double, height: Double, title: String?)
    }

    public let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    /// A short string for the log: `display 2560x1600`, `window 1440x900 @ 120,80 title="Mail"`.
    ///
    /// No id and no `pt`: this is the *why* of a cache line ("the stamp matched"), and the slot it is
    /// printed beside already names the source. A `nil` title is not printed at all, so a window the
    /// list has no name for reads as a rectangle rather than as `title=""`.
    public var label: String {
        switch kind {
        case let .display(width, height):
            return "display \(width)x\(height)"
        case let .window(x, y, width, height, title):
            let rect = "window \(Self.number(width))x\(Self.number(height))"
                + " @ \(Self.number(x)),\(Self.number(y))"
            guard let title, !title.isEmpty else { return rect }
            return rect + " title=\"\(title)\""
        }
    }

    /// Integer when the number is one, otherwise one decimal — the same shape the wall's own debug
    /// lines use, so a bounds of `1440` does not print as `1440.0`. Non-finite values are printed as
    /// they are rather than converted (a NaN window is a real window at a real rectangle, and
    /// `Int(_:)` would trap).
    private static func number(_ value: Double) -> String {
        guard value.isFinite, abs(value) < 1e15, value == value.rounded() else {
            return String(format: "%.1f", value)
        }
        return String(Int(value))
    }
}

/// Everything `WallPictures.capture` reads to produce a picture, and nothing about where it goes.
///
/// The invalidation rule of the wall's picture cache is exactly this: a cached picture is reused iff
/// its key equals the new panel's key. What is **not** in the key is as deliberate as what is:
/// `slot`, `rect.row/col` and `placementID` say *where* a picture is placed, not *what* it is, so a
/// window that moves one card to the left keeps its payload. That is the whole of issue #100: a page
/// step changes placement for the stage (nothing) and identity for the cards, and only the genuinely
/// new panels are photographed.
public struct PanelKey: Equatable, Hashable {
    /// Which thing is photographed: a display number or a window number.
    public let source: WallPanel.Source
    /// What that thing's pixels depend on (see `PanelSourceStamp`).
    public let stamp: PanelSourceStamp
    /// The size the capture is asked for, i.e. the size the layout fitted the picture into.
    public let contentWidth: Int
    public let contentHeight: Int
    /// `QualityBudget.value`: a rung change quantises the payload differently, so it is dirty.
    public let quality: Int
    /// `!square`: the rounded corners are punched into the alpha channel, so toggling `--square`
    /// changes the pixels.
    public let rounded: Bool

    public init(source: WallPanel.Source, stamp: PanelSourceStamp, contentWidth: Int,
                contentHeight: Int, quality: Int, rounded: Bool) {
        self.source = source
        self.stamp = stamp
        self.contentWidth = contentWidth
        self.contentHeight = contentHeight
        self.quality = quality
        self.rounded = rounded
    }

    /// The key for a panel: everything `WallPictures.capture` reads, nothing about placement.
    ///
    /// `quality` and `rounded` are passed in because they are process-wide settings, not panel
    /// geometry (`WallPictures.quality`, `WallPictures.square`): the panel cannot know them, and a
    /// key that guessed would cache a picture the next `--wall-quality` could not use.
    public init(panel: WallPanel, quality: Int, rounded: Bool) {
        self.init(source: panel.source, stamp: panel.stamp,
                  contentWidth: panel.fit.contentWidth, contentHeight: panel.fit.contentHeight,
                  quality: quality, rounded: rounded)
    }
}
