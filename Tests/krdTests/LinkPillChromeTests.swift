import XCTest
import krdcore
@testable import krd

/// The pill itself: one widget in the chrome's table (issue #199).
///
/// Three things are pinned here, in the order they can go wrong:
///
/// 1. **The pill *is* a control.** It is drawn as a `ChromeWidget` with an action, so `route` answers
///    its cells and a click on them opens the panel whose `rtt` row names the setting. A pill stamped
///    into cells with an id and no action would be a readout that looks clickable — the failure mode
///    #200 deleted for every other control.
/// 2. **It appears only for `held`.** `fine`, `unknown` and — the important one — `slow` draw nothing:
///    a congested link has a minimum that climbed, the quality ladder already owns that case (#187),
///    and this pill's sentence is "the link is *not* slow".
/// 3. **It is cheap and it is idempotent.** One `held → held` draw is **0 B** (that is the wall's idle
///    contract in one line), and the repaint that puts the pill on screen is a few dozen bytes, far
///    under the 600 B hover budget the rest of the bar lives on — let alone the 6 KB panel budget.
final class LinkPillChromeTests: XCTestCase {
    // MARK: - fixtures

    private func metrics(link: LinkVerdict) -> ChromeMetrics {
        var m = ChromeMetrics()
        m.version = "test"
        m.target = "window 128444"
        m.title = "Terminal — admin — scroll.sh"
        m.clock = "20:07:17"
        m.fps = 18
        m.fpsTarget = 20
        m.mbps = 1.8
        m.scale = 1.0
        m.capMs = 42
        m.e2eMs = 61
        // The measurement the pill is about: OpenSSH's grid with a fast minimum underneath it.
        m.rttAvailable = true
        m.rttMs = 22.4
        m.rttP99Ms = 30.1
        m.rttMinMs = 0.7
        m.link = link
        return m
    }

    private func bar(cols: Int = 120, rows: Int = 30,
                     panel: ChromePanel? = nil) -> ChromeGeometry {
        // The picture gives up the rows a panel asks for (`Chrome.pictureRows`), exactly as the Desk
        // does before it lays the chrome out — a geometry that kept them would leave the box zero
        // rows tall and the panel assertions below would be measuring nothing.
        let picture = Chrome.pictureRows(paneRows: rows, bar: true, panel: panel, chrome: false)
        return Chrome.layout(paneCols: cols, paneRows: rows, imageCols: cols, imageRows: 1 + picture,
                            bar: true, dev: false, panel: panel)
    }

    private func draw(_ link: LinkVerdict, cols: Int = 120, panel: ChromePanel? = nil,
                      on chrome: Chrome = Chrome()) -> [UInt8] {
        chrome.draw(geometry: bar(cols: cols, panel: panel), metrics: metrics(link: link),
                    state: ChromeState(panel: panel))
    }

    // MARK: - 1. it is a control

    func testTheHeldPillIsOneWidgetWithAnAction() {
        let chrome = Chrome()
        let geo = bar()
        _ = draw(.held, on: chrome)
        guard let pill = chrome.widgets.first(where: { $0.id == "link" }) else {
            return XCTFail("the held link drew no widget: \(chrome.widgets.map(\.id))")
        }
        XCTAssertEqual(pill.role, .control(.openPanel(.stats)),
                       "the pill's click has to end somewhere a reader can act on")
        XCTAssertFalse(pill.disabled, "a pill nobody can click is a readout, and this one is not that")
        // Its cells route to it, and only to it: a control drawn is a control hit (#200).
        for y in pill.rect.row..<(pill.rect.row + pill.rect.height) {
            for x in pill.rect.col..<(pill.rect.col + pill.rect.width) {
                XCTAssertEqual(chrome.route(row: y + 1, col: x + 1, geometry: geo), .widget("link"),
                               "row \(y) col \(x) is the pill and must be forwarded")
            }
        }
        // On the bar's own row, where the furniture is.
        XCTAssertEqual(pill.rect.row, geo.barRow, "the pill belongs on the bar")
        // …and the panel it opens says what to do about it.
        let panel = draw(.held, panel: .stats)
        XCTAssertTrue(String(decoding: panel, as: UTF8.self).contains("ObscureKeystrokeTiming"),
                      "the panel the pill opens must name the setting that fixes it")
    }

    /// The click path runs the action the table carries, so the id alone buys nothing: this is the
    /// same lookup `chromeClick` does.
    func testAClickOnThePillIsTheStatsPanel() {
        let chrome = Chrome()
        let geo = bar()
        _ = draw(.held, on: chrome)
        guard let pill = chrome.widgets.first(where: { $0.id == "link" }) else {
            return XCTFail("no pill")
        }
        let hit = chrome.widget(row: pill.rect.row + 1, col: pill.rect.col + 1, geometry: geo)
        XCTAssertEqual(hit?.id, "link")
        guard case let .control(action)? = hit?.role else { return XCTFail("not a control") }
        XCTAssertEqual(action, .openPanel(.stats))
    }

    // MARK: - 2. only for held

    func testOnlyTheHeldLinkDrawsThePill() {
        let held = draw(.held)
        for quiet in [LinkVerdict.fine, .unknown, .slow] {
            let chrome = Chrome()
            let bytes = draw(quiet, on: chrome)
            XCTAssertNil(chrome.widgets.first(where: { $0.id == "link" }),
                         "\(quiet) drew the pill: \(chrome.widgets.map(\.id))")
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("keys held"),
                           "\(quiet) printed the pill's sentence")
            // A congested link's bar is byte-for-byte the healthy bar: `slow` is a verdict, not a
            // pill, and the only bytes that differ on a `held` link are the pill's own cells.
            XCTAssertEqual(bytes, draw(.fine), "\(quiet) changed the bar's bytes")
        }
        let healthy = draw(.fine)
        XCTAssertNotEqual(held, healthy, "the pill changed nothing on the bar")
        // The bar's other furniture is untouched by the pill: the numbers and both buttons survive.
        let chrome = Chrome()
        _ = draw(.held, on: chrome)
        XCTAssertTrue(chrome.widgets.contains { $0.id == "menu" })
        XCTAssertTrue(chrome.widgets.contains { $0.id == "shrink" })
        XCTAssertTrue(chrome.widgets.contains { $0.id == "numbers" })
    }

    /// A row too narrow for the pill *and* the traffic lights draws no pill at all, rather than one
    /// that lands on the dots: two widgets on one cell is the bug the table exists to prevent.
    func testANarrowBarDropsThePillInsteadOfOverlapping() {
        let chrome = Chrome()
        _ = draw(.held, cols: 24, on: chrome)
        XCTAssertNil(chrome.widgets.first(where: { $0.id == "link" }),
                     "a 24-column bar has no room for the pill: \(chrome.widgets.map(\.id))")
    }

    // MARK: - 3. the bytes

    func testThePillRepaintIsSmallAndAnUnchangedVerdictPaintsNothing() {
        // The frame before the symptom: the bar as it is on a healthy link.
        let chrome = Chrome()
        _ = draw(.fine, on: chrome)
        let appeared = draw(.held, on: chrome)
        print("pill repaint: \(appeared.count) B (fine -> held, 120x30 bar)")
        XCTAssertFalse(appeared.isEmpty, "the pill cost no bytes: it was not drawn")
        XCTAssertTrue(String(decoding: appeared, as: UTF8.self).contains("keys held"))
        XCTAssertFalse(String(decoding: appeared, as: UTF8.self).contains("\u{1B}_G"),
                       "the pill re-sent a picture")
        XCTAssertLessThan(appeared.count, 600, "\(appeared.count) B is over the bar's hover budget")
        XCTAssertLessThan(appeared.count, 6 * 1024, "\(appeared.count) B is over the 6 KB menu budget")
        // …and holding it costs nothing: the same verdict twice is not a repaint.
        XCTAssertEqual(draw(.held, on: chrome).count, 0,
                       "an unchanged verdict painted")
        // The way back out is the same handful of cells.
        let cleared = draw(.fine, on: chrome)
        print("pill cleared: \(cleared.count) B")
        XCTAssertLessThan(cleared.count, 600)
    }

    // MARK: - the wall's header row

    /// The wall is where a reader sits, so the same sentence is drawn there — right-aligned on the
    /// header row, with the counts keeping their cells. The bar and the wall read one string
    /// (`LinkVerdict.pill`), so they cannot come to describe one measurement differently.
    private func wall(cols: Int = 100, rows: Int = 30) -> (WallCanvas, WallLayout, WallModel) {
        let model = WallSource.demoModel()
        let display = model.displays[0]
        let layout = WallState().layout(cols: cols, rows: rows,
                                        displays: model.displays.count,
                                        windows: model.windows.count,
                                        stageAspect: Double(display.width) / Double(display.height))
        return (WallCanvas(), layout, model)
    }

    func testTheWallHeaderCarriesTheSamePillOnlyWhileHeld() {
        let (canvas, layout, model) = wall()
        let held = canvas.lines(cols: 100, rows: 30, model: model, layout: layout, focus: nil,
                                link: .held)
        let header = held[layout.headerRow - 1]
        XCTAssertTrue(header.contains("[ keys held ]"), "the wall's header lost the pill: \(header)")
        XCTAssertTrue(header.contains("windows"), "the pill ate the counts: \(header)")
        // Right-aligned on the content columns, i.e. it ends where the text can end — measured in
        // cells, not characters, because the bullet and the dots are not all one width.
        guard let range = header.range(of: "[ keys held ]") else { return XCTFail("no pill") }
        XCTAssertEqual(DisplayWidth.of(String(header[..<range.upperBound])), layout.contentCols,
                       "the pill is not the right end of the content columns: \(header)")
        for quiet in [LinkVerdict.fine, .unknown, .slow] {
            let lines = canvas.lines(cols: 100, rows: 30, model: model, layout: layout, focus: nil,
                                     link: quiet)
            XCTAssertFalse(lines[layout.headerRow - 1].contains("keys held"),
                           "\(quiet) drew the wall's pill")
        }
    }

    func testTheWallsPillRepaintIsSmallAndAnUnchangedVerdictPaintsNothing() {
        let (canvas, layout, model) = wall(cols: 100, rows: 30)
        func paint(_ link: LinkVerdict) -> [UInt8] {
            canvas.draw(cols: 100, rows: 30, model: model, layout: layout, focus: nil, link: link)
        }
        _ = paint(.fine)
        let appeared = paint(.held)
        print("wall pill repaint: \(appeared.count) B (fine -> held, 100x30 wall)")
        XCTAssertFalse(appeared.isEmpty, "the wall's pill cost no bytes: it was not drawn")
        XCTAssertTrue(String(decoding: appeared, as: UTF8.self).contains("keys held"))
        XCTAssertLessThan(appeared.count, 600, "\(appeared.count) B is over the hover budget")
        XCTAssertEqual(paint(.held).count, 0, "an unchanged verdict repainted the wall")
        let cleared = paint(.fine)
        print("wall pill cleared: \(cleared.count) B")
        XCTAssertLessThan(cleared.count, 600)
    }
}
