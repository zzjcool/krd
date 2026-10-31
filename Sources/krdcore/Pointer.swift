/// What a pointer is doing: what it is over, and whether a button is down.
///
/// Two surfaces in krd answer a pointer, and neither has a hover of its own — both are drawn as
/// text, and text does not know where the mouse is. This is the value the *input* path computes from
/// the click table itself (`WallState.focus(atRow:col:)` on the wall, `Chrome.route` on the chrome)
/// and the painter styles. The wall's pointer is this with `WallState.Focus` as the target
/// (`WallPointer`); the chrome's is this with a widget id (`ChromeState.pointer`). One shape for
/// both, because "what am I over, is it pressed" is the same question twice (issue #200), and two
/// answers to it is how a highlight ends up sitting on something a click would not act on.
///
/// It deliberately carries nothing about *what a click does* — a pointer is a question, not an
/// action.
public struct Pointer<Target: Equatable>: Equatable {
    /// The item under the pointer, in the surface's own vocabulary: a display (the stage) or a window
    /// (a card or its caption) on the wall, a widget id on the chrome. `nil` is the furniture, which
    /// nothing highlights.
    public var over: Target?
    /// A press that has not been released yet. The only feedback there is before the action it
    /// belongs to lands (a mirror opening, a panel appearing), so it has to be visible in the cells
    /// the target drew — the wall reverses its caption, the chrome fills its button.
    public var down: Bool

    public init(over: Target? = nil, down: Bool = false) {
        self.over = over
        self.down = down
    }

    /// The target a press is on: down on something, or nothing.
    public var pressed: Target? { down ? over : nil }

    /// The shape the *terminal's* pointer should take while this is the pointer (OSC 22, #202).
    ///
    /// A projection of `over` and of nothing else, which is what makes it a **class** rather than a
    /// per-cell answer: two targets a click both enters are the same "something a click enters", so
    /// the hand stays on across the gap between them and nothing is emitted. The furniture — a bar's
    /// arrows, `⤢ N`, a separator, the clock — answers a click on the wall too, but it is not a
    /// target (the plan's decision, and why the bar's ends are dimmed), so the terminal keeps its own
    /// pointer there. `down` is not in it either: a press is not a different shape, it is the same
    /// target being pushed (the surface already says so in reverse video).
    ///
    /// `text` has no case to reach: neither surface has a text field, and only the wall emits a shape
    /// at all — a mirrored desktop has a real pointer of its own, so `main.swift` assigns
    /// `writer.pointerShape` from the wall alone — which keeps #202 at two shapes and leaves the
    /// third to later work.
    public var shape: PointerShape { over == nil ? .default : .pointer }
}
