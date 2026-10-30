import CoreGraphics
import Foundation

/// One picture the wall wants on screen, decided from the layout and the world (design §6.6).
///
/// Pure: ids and geometry only. What happens with it — capture, compose, cache, emit — is the app's
/// business, which is what lets the whole plan be tested without a window server.
public struct WallPanel: Equatable {
    /// Where a picture's pixels come from. The ids are the window server's own: a display number,
    /// or a window number (`kCGWindowNumber`).
    public enum Source: Equatable {
        case display(UInt32)
        case window(UInt32)
    }

    /// 0 is the stage, 1... are the cards of the current page in the layout's order.
    public let slot: Int
    public let source: Source
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

    public init(kind: Kind, aspect: Double) {
        self.kind = kind
        self.aspect = aspect
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
        for (index, rect) in layout.cards.enumerated() {
            guard index < cardSources.count, let source = cardSources[index], source.isUsable,
                  let panel = make(slot: 1 + index, source: source, rect: rect,
                                   cellW: cellW, cellH: cellH) else { continue }
            panels.append(panel)
        }
        return panels
    }

    private static func make(slot: Int, source: PanelSource, rect: CellRect,
                             cellW: Double, cellH: Double) -> WallPanel? {
        guard !rect.isEmpty, cellW > 0, cellH > 0 else { return nil }
        let fit = PanelImage.fit(aspect: source.aspect, in: rect, cellW: cellW, cellH: cellH)
        guard !fit.isEmpty else { return nil }
        let pixelWidth = max(1, Int((Double(rect.cols) * cellW).rounded()))
        let pixelHeight = max(1, Int((Double(rect.rows) * cellH).rounded()))
        let id: WallPanel.Source
        switch source.kind {
        case let .display(displayID): id = .display(displayID)
        case let .window(windowID): id = .window(windowID)
        }
        return WallPanel(slot: slot, source: id, rect: rect,
                         pixelWidth: pixelWidth, pixelHeight: pixelHeight, fit: fit)
    }
}
