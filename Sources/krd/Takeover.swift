import Darwin
import Foundation

/// Taking the screen from an earlier krd: ScreenCaptureKit gives one executable one client.
///
/// WHY this exists. While an earlier `krd` is alive, every stream the newcomer asks for dies at once
/// with `-3805` ("failed during stream due to application connection being interrupted") and every
/// panel capture comes back empty — a wall that paints its text, its cards and its captions and not
/// one picture (`docs/TROUBLESHOOTING.md` §23c, and `Desk.enterFocus`'s four-way measurement, which
/// also proves the identity is the executable's *path*: the same binary copied elsewhere streams
/// beside a running wall).
///
/// The earlier process is usually the reader's own: a terminal closed on it, `sshd` kept the session
/// alive, and it went on holding the client. Measured on the tart VM: `pgrep -x krd` found an orphan
/// whose parent was `sshd-session: admin@notty` with its tty gone, and every `krd` started after it
/// painted a pictureless wall for as long as it lived — the reader's own words for it were "第一次
/// 打开可以的，退出了，再开就没有图".
///
/// WHY killing, rather than waiting or asking. One user, one pane, one screen: the session the
/// reader is looking at is the one that should have the screen, and the older one has no reader left
/// to notice anything — waiting for it is waiting forever.
///
/// WHY SIGTERM and then SIGKILL. A healthy older krd handles SIGTERM (`shutdown()`) and leaves
/// cleanly. One wedged *inside* a ScreenCaptureKit call does not: measured on the VM, `pkill` left it
/// running (23 % CPU, in `RunLoop.main.run()`) and only `pkill -9` took it down — and an ignored
/// signal is not a released claim, which is why the new process still had no pictures.
///
/// WHO decides. Election by pid, not a lock file: when two copies start in the same second they see
/// each other, and the higher pid is the newer process — the one the reader just launched. It takes
/// the screen; the other copy leaves everything alone and says so in its log. No file to leave
/// behind, no wait for a lock a dying process may be holding, and pid wrap-around is the only way to
/// pick the wrong winner (harmless: one survivor either way).
///
/// WHAT it will not touch. A listing, a run that never captures (`--selftest`, `--bench`, `--replay`,
/// `--mock`, `--demo`), a run with a pipe where the picture goes, and `--no-takeover` — see
/// `Desk.capturesTheScreen` and `wanted`. Those are the paths the repo's own recipes and test suite
/// use, and killing a live wall for a `--selftest` hash would be worse than the bug this fixes.
///
/// One thing it cannot tell apart: a *short-lived* diagnostic of the same path that happens to run
/// at the same moment — `krd --list`, `krd --dump-termcaps`, `krd ax …` — is a copy like any other
/// and would be asked to leave. They exit in milliseconds and say nothing about a picture, so the
/// cost is a retry; reading argv (`KERN_PROCARGS2`) to tell them apart is not worth the surface
/// until someone actually loses one.
enum Takeover {
    /// One running copy of an executable, as the kernel reports it.
    struct Candidate: Equatable {
        let pid: Int32
        let path: String
    }

    /// What a takeover did, for the one line in the log.
    struct Outcome: Equatable {
        /// The copies that were there when the newcomer looked, in pid order.
        var asked: [Int32] = []
        /// The copies that had to be killed, because SIGTERM left them running.
        var killed: [Int32] = []
        /// A newer copy was taking the screen at the same moment, so this one left it alone.
        var outracedBy: Int32? = nil
        /// What the whole thing cost, measured rather than argued about.
        var milliseconds: Int = 0

        var isEmpty: Bool { asked.isEmpty && outracedBy == nil }

        /// The log line. One line, with numbers: it is what a session that still has no pictures is
        /// read against, so it says which pids went, how long it took, and never a claim it did not
        /// carry out.
        var sentence: String {
            if let pid = outracedBy {
                return "krd \(pid) is taking the screen; leaving it to that one"
            }
            guard !asked.isEmpty else { return "no earlier krd held the screen" }
            let list = asked.map(String.init).joined(separator: " ")
            let took = "took the screen from krd \(list) in \(milliseconds) ms"
            guard !killed.isEmpty else { return took }
            let stuck = killed.map(String.init).joined(separator: " ")
            return took + "; \(stuck) did not leave on SIGTERM and was killed"
        }
    }

    /// Whether this run may take the screen over at all. Pure, so each refusal is a test.
    ///
    /// Three questions, and each one has a case that must not steal:
    ///
    /// - `capturesTheScreen`: the collision this exists for is a ScreenCaptureKit client, and a run
    ///   that paints without one (`--selftest`, `--bench`, `--replay`, `--mock`, `--demo`, a listing)
    ///   has nothing to win by killing the reader's session (`Desk.capturesTheScreen`).
    /// - `isTerminal`: the *picture stream* is stdout (`main.swift`'s first rule), so that is the
    ///   descriptor that has to be a terminal. This is also what keeps the repo's recipes safe —
    ///   `KRD_DUMP=… krd --selftest … >/dev/null` (CONTRIBUTING.md, TESTING.md §) redirects stdout.
    /// - `--no-takeover`: the session that means to compare two panes side by side.
    static func wanted(options: Options, capturesTheScreen: Bool, isTerminal: Bool) -> Bool {
        capturesTheScreen && isTerminal && !options.noTakeover
    }

    /// Which of these copies have to go before `ownPID` can be the executable's one capture client.
    ///
    /// The match is on the whole path, not the name: the collision is keyed to the executable image
    /// the window server knows, so `/Users/me/bin/krd` and `/tmp/krd` are two clients and both may
    /// capture (measured — that is why `enterFocus` can get away with `execv` at all).
    static func otherCopies(_ candidates: [Candidate], ownPath: String, ownPID: Int32) -> [Candidate] {
        candidates
            .filter { $0.pid > 0 && $0.pid != ownPID && $0.path == ownPath }
            .sorted { $0.pid < $1.pid }
    }

    /// Every running process, with the path of the executable it is running (`libproc`'s answer, the
    /// same one the window server keys its client to).
    ///
    /// The count first, then the list, then a retry with room to spare when the list came back full:
    /// a guess that stays full is a guess that silently stopped early, and a name that fell off the
    /// end could be the very copy holding the screen. A process that exits between the two calls, or
    /// whose path cannot be read (another user's, mostly), is skipped — it cannot collide with us.
    static func running() -> [Candidate] {
        let stride = Int32(MemoryLayout<pid_t>.size)
        var spare = 16
        for _ in 0..<3 {
            let counted = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
            guard counted > 0 else { return [] }
            let capacity = Int(counted) / Int(stride) + spare
            var pids = [pid_t](repeating: 0, count: capacity)
            let used = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(capacity) * stride)
            guard used > 0 else { return [] }
            let full = Int(used) >= capacity * Int(stride)
            if full {
                // Room was not enough: the rest of the table never arrived.
                spare *= 4
                continue
            }
            let count = Int(used) / Int(stride)
            var out: [Candidate] = []
            out.reserveCapacity(count)
            for pid in pids[0..<count] where pid > 0 {
                if let path = path(of: pid) { out.append(Candidate(pid: pid, path: path)) }
            }
            return out
        }
        return []
    }

    /// `PROC_PIDPATHINFO_MAXSIZE` as libproc defines it (`4 * MAXPATHLEN`): the header's macro is not
    /// visible to Swift, and the buffer has to be that big or `proc_pidpath` refuses with ENAMETOOLONG.
    static let pathBufferSize = 4 * 1024

    /// The executable `pid` is running, or nil when the kernel will not say.
    static func path(of pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: pathBufferSize)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer[0..<Int(length)], as: UTF8.self)
    }

    /// This process's own executable, from the same source as every candidate.
    static func ownPath() -> String { path(of: getpid()) ?? "" }

    /// Ask the copies to leave, and kill the ones a wedged capture call will not release.
    ///
    /// Two things are deliberate here. The path is checked again immediately before each signal: the
    /// list was taken milliseconds ago, and between the two a copy can exit and its pid be handed to
    /// something else. And only a `SIGKILL` that the kernel accepted is reported as a kill — a copy
    /// this process may not signal (another user's install at the same path) is left out of the line
    /// rather than described as something that happened.
    static func take(_ copies: [Candidate],
                     generousMilliseconds: Int = 600,
                     stepMilliseconds: Int = 20) -> Outcome {
        let started = Date()
        var outcome = performTake(copies,
                                  generousMilliseconds: generousMilliseconds,
                                  stepMilliseconds: stepMilliseconds)
        // Measured outside the return value: a `defer` here would mutate the local copy *after* the
        // value had been returned, which reads as "in 0 ms" for every takeover that ever ran.
        outcome.milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        return outcome
    }

    private static func performTake(_ copies: [Candidate],
                                    generousMilliseconds: Int,
                                    stepMilliseconds: Int) -> Outcome {
        var outcome = Outcome()
        let reachable = copies.filter { path(of: $0.pid) == $0.path }
        outcome.asked = reachable.map(\.pid)
        guard !reachable.isEmpty else { return outcome }
        for copy in reachable { kill(copy.pid, SIGTERM) }
        var alive = reachable
        var waited = 0
        while waited < generousMilliseconds, !alive.isEmpty {
            usleep(UInt32(stepMilliseconds) * 1000)
            waited += stepMilliseconds
            alive = alive.filter { isAlive($0.pid) }
        }
        guard !alive.isEmpty else { return outcome }
        outcome.killed = alive.filter { kill($0.pid, SIGKILL) == 0 }.map(\.pid)
        // SIGKILL is not returned until the target is gone, but the kernel still has to reap it.
        usleep(20 * 1000)
        return outcome
    }

    /// Whether `pid` is a running process. A zombie is not one — it has already left, it is only
    /// waiting to be reaped, and counting it would put 650 ms and a false sentence on every start.
    /// A process this one may not signal (`EPERM`) is another user's: alive, and not ours to take.
    static func isAlive(_ pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, Int32(PROC_PIDTBSDINFO), 0, &info, size) == size {
            // `SZOMB` from bsd/sys/proc.h, which Swift does not import.
            return info.pbi_status != 5
        }
        return kill(pid, 0) == 0 && errno != ESRCH
    }

    /// `wanted`'s yes, carried out: elect, list, choose, ask, kill.
    ///
    /// Nothing to take is the common case (one krd, started once) and costs one `proc_listpids`.
    static func takeTheScreen() -> Outcome {
        let mine = getpid()
        let path = ownPath()
        guard !path.isEmpty else { return Outcome() }
        let others = otherCopies(running(), ownPath: path, ownPID: mine)
        guard let highest = others.map(\.pid).max() else { return Outcome() }
        guard mine > highest else { return Outcome(outracedBy: highest) }
        return take(others)
    }
}
