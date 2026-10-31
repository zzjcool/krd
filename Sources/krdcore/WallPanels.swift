import CoreGraphics
import Foundation

/// One picture the wall wants on screen, decided from the layout and the world (design §6.6).
///
/// Pure: ids and geometry only. What happens with it — capture, compose, cache, emit — is the app's
/// business, which is what lets the whole plan be tested without a window server.
public struct WallPanel: Equatable {
    /// Where a picture's pixels come from. The ids are the window server's own: a display number,
    /// or a window number (`kCGWindowNumber`).
    ///
    /// `Hashable` because it is half of a `PanelKey` (issue #100): the picture cache is keyed by
    /// "photographed what, in what shape".
    public enum Source: Equatable, Hashable {
        case display(UInt32)
        case window(UInt32)

        /// The stage is a display and a card is a window: the cache's one asymmetry (a display's
        /// picture has no age signal in its stamp, a window's does) hangs off this.
        public var isDisplay: Bool {
            if case .display = self { return true }
            return false
        }
    }

    /// 0 is the stage, 1... are the cards of the current page in the layout's order.
    public let slot: Int
    public let source: Source
    /// What the source's pixels depend on beyond its id — its size, and for a window its bounds and
    /// title. Carried through from `PanelSource` so a repaint can tell "the same picture" from "the
    /// same window, moved" without asking the window server again (`PanelKey`).
    public let stamp: PanelSourceStamp
    /// The cells the picture must fill exactly: mask rect == picture rect, so a failing capture
    /// never reflows the wall.
    public let rect: CellRect
    /// The panel in device pixels — `rect` at the terminal's cell size.
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Where the picture sits inside the panel and how big it is.
    public let fit: PanelFit

    /// Fixed per slot and reused on every repaint: a picture overwrites its own placement, so no
    /// delete is ever needed (and `a=d` drops the whole image set on Herdr and rex — Render.swift).
    public var imageID: Int { 5000 + slot }
    public var placementID: Int { 9000 + slot }

    /// The picture this panel wants, as the cache keys it (issue #100).
    ///
    /// `quality` and `rounded` are the process-wide knobs (`WallPictures.quality`/`.square`) rather
    /// than panel geometry: they change the pixels, so they belong in the key, but the panel is a
    /// pure layout value and does not know them.
    public func key(quality: Int, rounded: Bool) -> PanelKey {
        PanelKey(panel: self, quality: quality, rounded: rounded)
    }
}

/// A source, resolved by the caller: the painter knows which display is on stage and which windows
/// are on the current page; this type only carries what the picture maths needs.
public struct PanelSource: Equatable {
    public enum Kind: Equatable {
        case display(UInt32)
        case window(UInt32)
    }

    public let kind: Kind
    /// Width / height of the source in its own pixels.
    public let aspect: Double
    /// The source's own shape (size, and a window's bounds and title): the part of a picture's
    /// identity the layout cannot see (`PanelSourceStamp`). Defaulted so a caller that only has an
    /// id and an aspect (a test, a mock) still compiles — such a source simply never matches a real
    /// one in the picture cache, which is the safe direction.
    public let stamp: PanelSourceStamp

    public init(kind: Kind, aspect: Double,
                stamp: PanelSourceStamp = PanelSourceStamp(kind: .display(width: 0, height: 0))) {
        self.kind = kind
        self.aspect = aspect
        self.stamp = stamp
    }

    /// A source whose size is not known yet (a display that reports 0): no picture, no crash.
    public var isUsable: Bool { aspect > 0 && aspect.isFinite }
}

public enum WallPanels {
    /// The stage's picture and the visible cards' pictures, in layout order.
    ///
    /// `cardSources` is aligned with `layout.cards`: the caller resolved the page, because which
    /// page is showing is the wall's state, not geometry. A hole (`nil`, or no source for that
    /// slot) simply means that slot draws its placeholder.
    public static func plan(layout: WallLayout, cellW: Double, cellH: Double,
                            stageSource: PanelSource?,
                            cardSources: [PanelSource?]) -> [WallPanel] {
        var panels: [WallPanel] = []
        if let stageSource, stageSource.isUsable,
           let panel = make(slot: 0, source: stageSource, rect: layout.stage, cellW: cellW, cellH: cellH) {
            panels.append(panel)
        }
        // One height for the whole row. Each picture is fitted to its own aspect, so a 16:9 window
        // ends up shorter than a square one and the row's top and bottom edges disagree - review
        // called that out ("窗口的最高高度需要保持一致"). The tallest height every picture can reach
        // without cropping or stretching is the *widest* window's, so the row shares that one: the
        // wide picture keeps the full width and nothing is cut or distorted. The price is that one
        // wide window shortens its neighbours for as long as it is on the page.
        let shared = sharedCardHeight(layout: layout, cardSources: cardSources,
                                      cellW: cellW, cellH: cellH)
        for (index, rect) in layout.cards.enumerated() {
            guard index < cardSources.count, let source = cardSources[index], source.isUsable,
                  let panel = make(slot: 1 + index, source: source, rect: rect,
                                   cellW: cellW, cellH: cellH, maxHeight: shared) else { continue }
            panels.append(panel)
        }
        return panels
    }

    /// The height every card's picture is drawn at, or `nil` when there is nothing to line up.
    ///
    /// `nil` for a single card: it has no neighbour to agree with, so it may use the whole rect.
    public static func sharedCardHeight(layout: WallLayout, cardSources: [PanelSource?],
                                        cellW: Double, cellH: Double) -> Int? {
        var heights: [Int] = []
        for (index, rect) in layout.cards.enumerated() {
            guard index < cardSources.count, let source = cardSources[index], source.isUsable,
                  !rect.isEmpty else { continue }
            let fit = PanelImage.fit(aspect: source.aspect, in: rect, cellW: cellW, cellH: cellH)
            if !fit.isEmpty { heights.append(fit.contentHeight) }
        }
        return heights.count > 1 ? heights.min() : nil
    }

    private static func make(slot: Int, source: PanelSource, rect: CellRect,
                             cellW: Double, cellH: Double, maxHeight: Int? = nil) -> WallPanel? {
        guard !rect.isEmpty, cellW > 0, cellH > 0 else { return nil }
        let fit = PanelImage.fit(aspect: source.aspect, in: rect, cellW: cellW, cellH: cellH,
                                 maxHeight: maxHeight)
        guard !fit.isEmpty else { return nil }
        // The panel **is** the picture: `rect` is the fitted rectangle, not the band it was fitted
        // into, and the pixels are the picture's own size. Two reasons, both measured on a pane that
        // reports no pixel size:
        //
        // 1. A panel-sized canvas with transparent bars around the picture is only invisible on a
        //    terminal that lets the background through image alpha. Rex paints it **black**, so a
        //    picture occupying 64% of its canvas read as "the display is smaller than its frame,
        //    with a black ring" - the report that produced this. Cells outside the picture are now
        //    simply unpainted, exactly like the mirror's leftover cells.
        // 2. Keeping the band meant the caption row sat under the band's bottom edge, so freeing the
        //    picture from the band would have left the caption floating rows below its picture.
        let id: WallPanel.Source
        switch source.kind {
        case let .display(displayID): id = .display(displayID)
        case let .window(windowID): id = .window(windowID)
        }
        // The fit's offsets are the padding inside the band, and this panel has no band: the picture
        // is cropped to `cellRect` and starts at 0,0. Reporting the band's padding here would tell
        // `compose` to shift the picture inside a canvas exactly its own size (and the panel would
        // clip its own left column), so the panel states the offsets it actually has.
        let picture = PanelFit(contentWidth: fit.contentWidth, contentHeight: fit.contentHeight,
                               originX: 0, originY: 0, cellRect: fit.cellRect)
        return WallPanel(slot: slot, source: id, stamp: source.stamp, rect: fit.cellRect,
                         pixelWidth: fit.contentWidth, pixelHeight: fit.contentHeight, fit: picture)
    }
}
