import Foundation

/// How krd answers "am I inside a multiplexer?" (`--passthrough`, issue #107).
///
/// `auto` is the default because the answer is knowable: tmux sets `TERM=tmux-256color` and screen
/// sets `screen-*`, and over ssh the *client's* `TERM` is what the far side sees, so the multiplexer
/// is visible even when it runs locally. `on`/`off` exist because a server can force `TERM=xterm`
/// inside a tmux session, which is exactly the case where guessing fails and a human can say so.
public enum PassthroughMode: String, CaseIterable {
    case auto
    case on
    case off

    /// `--passthrough <spec>` / `KRD_PASSTHROUGH`, or `nil` for a typo (the caller names the flag).
    public init?(spec: String) {
        self.init(rawValue: spec.lowercased())
    }
}

/// The DCS passthrough envelope tmux forwards to the terminal behind it (issue #107).
///
/// Why krd needs it: krd's whole transport is the one kitty designed *for* multiplexers (unicode
/// placeholders, `U=1`), but the virtual placement that carries it is an APC, and tmux consumes an
/// APC body itself (`input_state_apc_string`, `tmux/input.c`) instead of forwarding it. What is left
/// on the pane is the placeholder cells' missing-glyph boxes — exactly the failure krd's own docs
/// warn about for a terminal that ignores `U=1`. The documented way through is `\ePtmux;…\e\`
/// (`tmux.1`, pane option `allow-passthrough`, default off), which is what every kitty-graphics
/// program ships (`icat`, `mpv --vo=kitty`, `bicat`).
///
/// Two properties matter and both are pinned in `TmuxPassthroughTests`:
/// - every `ESC` inside the envelope is doubled, because tmux un-doubles inside a DCS
///   (`input_state_dcs_escape`) and needs the *doubled* `ESC ESC \` to find where the payload ends;
/// - it is a pure string transform, so `wrap`/`unwrap` are inverses on the sequences krd emits and
///   the wrapped stream is the raw stream with envelopes added, nothing else.
public enum TmuxPassthrough {
    /// `ESC P tmux;` — tmux strips this prefix and passes the rest through.
    public static let prefix = "\u{1B}Ptmux;"
    /// The envelope's terminator, the same ST that ends every APC/DCS.
    public static let terminator = "\u{1B}\\"

    /// `ESC Ptmux;` + an APC introducer whose `ESC` is already doubled: the open half of the
    /// emission fast path, which is what makes wrapping an APC cost a prefix and one doubled ESC
    /// instead of a copy of the payload (11 bytes in all, with `close`). Equal to `prefix + doubled(ESC _)` by construction, and
    /// the test pins `open + body + close == wrap(ESC _ G<body> ESC \)`.
    public static let open = prefix + "\u{1B}\u{1B}_"
    /// `ESC ESC \ ESC \`: the doubled ST that closes the APC, then the envelope's own ST.
    public static let close = "\u{1B}\u{1B}\\" + terminator

    /// Wrap one complete APC/DCS sequence (`ESC _ … ESC \`) — the pure form.
    public static func wrap(_ sequence: String) -> String {
        var bytes = Array(prefix.utf8)
        bytes.reserveCapacity(sequence.utf8.count + prefix.utf8.count + terminator.utf8.count + 8)
        for byte in sequence.utf8 {
            if byte == 0x1B { bytes.append(0x1B) }   // doubling, never optional (see above)
            bytes.append(byte)
        }
        bytes.append(contentsOf: terminator.utf8)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The inverse, or `nil` when `wrapped` is not an envelope (`unwrap` is what the tests and a
    /// future dump analyser use; nothing on the hot path).
    ///
    /// Rejects a half-doubled payload: a lone `ESC` inside the envelope would mean tmux and krd
    /// disagree about where the envelope ends, which is the bug this feature cannot afford.
    public static func unwrap(_ wrapped: String) -> String? {
        let bytes = Array(wrapped.utf8)
        let head = Array(prefix.utf8), tail = Array(terminator.utf8)
        guard bytes.count >= head.count + tail.count,
              Array(bytes[0..<head.count]) == head,
              Array(bytes[(bytes.count - tail.count)...]) == tail else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(bytes.count - head.count - tail.count)
        var i = head.count
        let end = bytes.count - tail.count
        while i < end {
            if bytes[i] == 0x1B {
                guard i + 1 < end, bytes[i + 1] == 0x1B else { return nil }   // lone ESC: not ours
                out.append(0x1B)
                i += 2
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Does this `TERM` come from a multiplexer krd can wrap for? tmux is `tmux-*`, screen is
    /// `screen-*`; a `TMUX` variable alone is not enough (it is absent on the far side of an ssh
    /// where the tmux is local, which is the case this feature exists for).
    public static func looksMultiplexed(term: String) -> Bool {
        let term = term.lowercased()
        return term.hasPrefix("tmux") || term.hasPrefix("screen")
    }

    /// The decision, and the sentence the log gets: which input decided it.
    public struct Decision: Equatable {
        public let on: Bool
        public let why: String
    }

    /// `--passthrough` wins over `KRD_PASSTHROUGH`, which wins over `auto`'s `TERM` guess.
    ///
    /// `flag` is `nil` when the flag was not typed (typing `auto` is the same answer as not typing
    /// anything, but it still counts as the user having asked, so the environment is not consulted).
    public static func resolve(flag: PassthroughMode?, env: [String: String]) -> Decision {
        if let flag {
            return Decision(on: flag != .off,
                            why: "--passthrough \(flag.rawValue)")
        }
        if let spec = env["KRD_PASSTHROUGH"], let mode = PassthroughMode(spec: spec) {
            return Decision(on: mode != .off, why: "KRD_PASSTHROUGH=\(spec)")
        }
        let term = env["TERM"] ?? ""
        let on = looksMultiplexed(term: term)
        return Decision(on: on,
                        why: on ? "TERM=\(term)" : "TERM=\(term.isEmpty ? "unset" : term)")
    }
}
