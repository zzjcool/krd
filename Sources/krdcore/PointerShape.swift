/// The shape the *outer* terminal draws for its mouse while krd owns the pane (issue #202).
///
/// The hover (#195) answers the reader inside the pane — a card's caption reverses. The terminal's
/// own pointer is a second, separate thing, and a program names it with `OSC 22 ; <shape> ST`. The
/// UI v2 plan (`docs/design-ui-v2.zh-CN.md` §4) allows three shapes; the wall uses two:
///
/// - `.pointer` (a hand) over anything that **enters** — the stage, a card, either one's caption;
/// - `.default` over the wall's own furniture (the bar's arrows and shaft, `⤢ N`, the footer) and
///   over nothing at all. A page step is a click, not a target, which is the same decision that
///   dims the bar's ends.
///
/// `text` is deliberately **not** a case. There is no text field in the wall (the footer is a hint,
/// the header a count), so the third shape belongs to the mirror's later work; a case nobody can
/// reach is a case that rots. When a text field exists, it is a `case` here plus one line in
/// `Pointer.shape` — the emission, the class rule and the teardown reset are already written
/// against "whatever the surface asked for".
///
/// Two facts, both measured in the recon that shaped this issue, decide everything below:
///
/// - Both terminals krd is tested against (Rex, Ghostty 1.4.0) switch **immediately**, and the shape
///   survives a repaint — so it may be sent on a change and not per frame.
/// - It is reset by the **mouse-mode toggles**. That is why `ScreenWriter`'s book of what the pane
///   holds is forgotten when a session starts and again when a reader turns the mouse modes on
///   (`forgetPointerShape`), instead of being trusted across either.
///
/// The sequence is 14 B (`ESC ] 22 ; pointer ESC \`, measured: 5 for the introducer, 7 for the name,
/// 2 for `ST`), against a hover repaint of 39-97 B — and it is one shape per *class* change, which is
/// why a hover that moves inside one card still sends nothing at all.
public enum PointerShape: String {
    case `default`
    case pointer

    /// `ESC ] 22 ; <name> ESC \` — ST, not BEL: it is what §6.6's neighbours use, and both terminals
    /// take it.
    ///
    /// Deliberately **not** wrapped in tmux's DCS passthrough envelope, even though the envelope is a
    /// pure re-escaping and could carry it (that is how an OSC 52 write gets past a multiplexer). The
    /// wall must not depend on the shape having any effect, and a passthrough that only works with
    /// `allow-passthrough on` is exactly a dependency: §6.6's "not wrapped" table says so, and the
    /// consequence is that under tmux the shape simply does not change.
    public var sequence: String { "\u{1B}]22;\(rawValue)\u{1B}\\" }
}
