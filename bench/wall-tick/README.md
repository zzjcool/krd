# wall-tick — probes for the wall's 1 s idle tick (incomplete)

Two standalone probes for `refreshWall(force:)` (`Sources/krd/main.swift:1248`): the cost of
the calls a tick may repeat on a completely static wall — `WallSource.model()`
(`CGWindowListCopyWindowInfo` + `NSWorkspace.runningApplications`) and one `TIOCGWINSZ`.

`tick_cost.swift` times them in isolation, `tick_harness.swift` drives `krd` under a pty.

**Status: drafted, not measured.** This sweep ran out of budget before the numbers existed, so
nothing here is evidence yet and no claim is made about the idle tick's cost.
