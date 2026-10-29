# 排障手册

[English](TROUBLESHOOTING.md) | 简体中文

下面每一条都是这个项目真踩过的坑，按「现象 → 根因 → 对策」写。第 1~4 节里很多看起来像 krd 的 bug，
其实是终端或 macOS 的固有性质；第 5 节是怎么在「屏幕在骗你」的时候把事实查出来。

先记住这几条命令，读下去会反复用到：

```bash
krd --selftest --no-input        # 渲染器好不好？(不需要权限，不碰采集)
krd --list                       # 屏幕录制权限给了吗？窗口能枚举吗？
krd --debug                      # 日志在哪：会打一行 "krd: logging to <path>"
KRD_Q=0 krd --no-input           # 终端到底回了什么？
KRD_DUMP=/tmp/d.bin krd …        # 把发出的每个字节存下来，离线比对
```

## 1. 协议与终端

### 1. 黑屏，`KRD_Q=0` 里能看到 `EINVAL: decompression failed`

**根因。** `o=z` 要的是 RFC 1950 zlib：2 字节头 + deflate 体 + Adler-32 尾。Apple 的
`COMPRESSION_ZLIB` 产出的是*裸* DEFLATE（没有头、没有校验和），终端解不了；而 `q=2` 把错误也吞了，
于是你只看到黑屏。
**对策。** 用系统 libz 的 `compress2()`（`CZlib` 模块，level 5，见 `Render.swift`）。这个协议下永远
不要用 `COMPRESSION_ZLIB`。

### 1b. 以前正常的终端上出现黑块或花屏（0.1.2+）

**原因。** 从 0.1.2 起线上格式是 `f=24`（RGB）而不是 `f=32`（RGBA）：桌面不透明，alpha 字节是纯开销
（占载荷 25 %）。能处理 `f=32` 的终端都能处理 `f=24`——两者只差每像素字节数——但自己手写 RGB 路径
的终端仍可能出错，而 `q=2` 会让它静默失败。
**对策。** `krd --format rgba`（或 `KRD_FORMAT=rgba`）可以把载荷逐字节退回旧格式。如果这样就好了，
那是终端的 bug，值得上游报，不是 krd 的。

### 2. 黑屏，而且任何地方都没有报错

**根因。** `q=2` 会吞掉所有协议回复，包括错误。这是正确的默认值（否则回复会从 stdin 回来被打进桌面），
但它把「为什么没画出来」一起藏了。
**对策。** 用 `KRD_Q=0 krd --no-input` 复现，读回复（`OK` / `EINVAL: …` / `ENOENT: …`）。不要开着输入
的时候用 `KRD_Q=0`。

### 3. 加了「逐块瓦片删除」之后整幅画面被清空

**根因。** 有些终端把 `a=d,i=<id>` 实现成「丢掉整批图像」。于是「先删旧 placement 再放新的」这个最直观
的方案会让 pane 直接黑掉；老实实现的终端上还会闪一帧。
**对策。** krd 永远不逐块删除：`iid = 100 + index`、`pid = 1000 + index` 整场会话固定，每帧覆盖同一个
placement。只有会话收尾和显式 resize 才发 `a=d,d=a`。

### 4. `a=d` 写在 `?2026` 块内部更糟

**根因。** 在同步更新块里做删除，可能连带干掉终端正攒着的那一整批，而不只是点名的那个 image。
**对策。** 真需要删除就放在任何 `?2026h … ?2026l` 块*外面*。krd 只在 `clear()`/`endSession()` 里发
`a=d,d=a`，别处不发。

### 5. 静止画面永远不出现，直到有别的东西打印

**根因。** 有的终端要等到下一次输出周期才提交 placement。画面不变时 krd 什么都不发，于是最后一帧的
placement 可能永远没被提交。
**对策。** `ScreenWriter.nudge()` 在「采到一帧但没有脏瓦片」时补一个 `ESC[?25l`。（真正静止的桌面一个
字节都不发，这是故意的 —— 那种情况下上一帧已经被它自己的瓦片写入提交过了。）

### 6. `kill -9` 之后 pane 死了：连文字都不显示

**根因。** 进程死在一条 APC（`ESC _ G …`）中间，终端的解析器在等 `ST` 结束符，之后所有字节都被吞掉 ——
看起来像是会话坏了，其实是解析器状态坏了。
**对策。** krd 启动时自愈：`beginSession()` 先写 `ESC \`（补 APC）+ `ESC[?2026l`（补同步块）+
`?1003l ?1002l ?1006l ESC[0m ?25h`，然后才切备用屏。手工修：`printf '\033\\\033[?2026l\033[?25h'`。尽量别
`kill -9`，Ctrl-\\ 或 `kill`（SIGTERM）会走清理路径。

### 7. 瓦片贴错位置，或者几帧之后整屏开始滚

**根因。** 少了 `C=1`：贴图会移动光标，有些终端会推到图后面，也就是推到/推过最后一行；在最后一行写入会
触发整屏滚动。而每块瓦片都靠绝对 `CUP` 定位，一滚整幅画面就跟着错。
**对策。** 每个 placement 都带 `C=1`（`ScreenWriter.emit`、`emitFullFrame`）。

### 8. 某一块瓦片一直显示旧内容

**根因。** 老方案是每帧轮换 image id，结果两张图占同一块格子，终端认为「在上面」的那张可能是旧的。
**对策。** 每块瓦片一个 image id **加**一个 placement id，永久复用（§3）。如果新终端上看到这个现象，
那是它 placement 覆盖语义的问题，请带上 `KRD_QUADRANTS=1` 的输出提 issue。

### 9. 某个终端上 `?2026` 反而破坏了图像放置

**根因。** 同步更新支持参差不齐，有的终端会延迟、重排甚至丢掉块内的图形命令。
**对策。** `KRD_NOSYNC=1 krd` 去掉每块瓦片外面的包装（只丢逐块原子性，别的没影响）。如果这样就正常了，
说明是该终端的 `?2026` 实现有问题，记进兼容矩阵。

## 2. 几何与布局

### 10. 画面比例不对，或者在大 pane 里缩成一小块

**根因。** `TIOCGWINSZ` 的 `ws_xpixel`/`ws_ypixel` 返回 0（sshd 建的 pty、还没布局的 pane 都是这样），
单元格尺寸只能靠猜。
**对策。** 三级回退：`CSI 16 t` + `CSI 14 t` 查询（250 ms）→ stdout/stdin/`/dev/tty` 的 `TIOCGWINSZ`
→ `--cell <w>x<h>`（默认 `8x20`）。如果你的终端两个查询都不答，就把真实单元格尺寸显式传进去，比如
`--cell 17x33`。

### 11. 启动就卡住：一个字都不输出，进程干等

**根因。** macOS 上 `c_cc[0]`/`c_cc[1]` 是 **`VEOF`/`VEOL`**，不是 `VMIN`/`VTIME`。按序号写等于没改，
fd 仍然处于阻塞模式，第一次 `read()` 永不返回。
**对策。** 用 `p[Int(VMIN)]` / `p[Int(VTIME)]`（`Geometry.query()` 和 `InputReader.start()` 都是这么写的），
或者干脆不做阻塞读 —— 输入循环用的是带 100 ms 超时的 `poll()`。

### 12. 走 SSH 之后 pane 是 80×24，画面被压扁

**根因。** stdin 没有 tty：`sshd` 只有在 `-t` 时才分配 pty，没有 pty 时几何回退到 80×24，同时输入被禁用。
**对策。** `ssh -t user@host ~/bin/krd …`，永远带 `-t`。（`ssh host krd` 就是那个错误写法；krd 会明确
打印警告。）

### 13. 拉伸窗口之后画面变糊或偏了

**根因。** resize 路径只用 `TermGeometry.read()` 重新测量，不做 CSI 查询；在不汇报像素尺寸的 pty 上它会
退到 `--cell`，而那个值可能已经和新单元格尺寸不符。
**对策。** 这类终端请显式给 `--cell`，或者先定好窗口大小再依赖像素精度。`SIGWINCH` 仍然会触发重排布局、
`writer.clear()` 和按新尺寸重启流；布局不会停留在旧值，只是可能「信息不足」。

## 3. 输入

### 14. 键鼠毫无反应，日志里有 `input DISABLED`

**根因。** stdin 不是 tty（见第 12 条）。这种情况下 krd 故意不打开鼠标上报，否则终端的上报会当文字糊到
画面上。
**对策。** 用 `ssh -t`。本机跑的话要在真终端里跑，别把 stdin 重定向到文件或管道。

### 15. 点击总偏一格 / 点不中小控件

**根因。** 终端不认 `?1016h`（SGR-Pixels），一直发单元格坐标；一个格子约 17×33 px，对 12 点的按钮来说
太粗了。
**对策。** krd 这边没什么可修的 —— 两套坐标它都映射对了（见
[PROTOCOL](PROTOCOL.zh-CN.md#71-单元格坐标-vs-像素坐标以及降级判定)）。需要像素精度就换一个实现了
`?1016h` 的终端（rex、Ghostty、kitty）。

### 16. `--dry-run` 把画面搞花了

**根因。** `--dry-run` 只阻止 `CGEvent` 注入，轨迹仍然走 `Log`；而没加 `--debug`/`--log` 时日志句柄是
stderr —— 也就是 pty，直接糊在瓦片上。
**对策。** `krd --dry-run --debug`（写文件）或者 `--dry-run --log /tmp/krd.log`，然后去读文件。

### 17. Ctrl-C 停不下来

**根因。** 设计如此：Ctrl-C 原样转发给远端桌面，和真键盘一样；tty 上的信号也被关了（`ISIG` 关掉），
这样字节才能送到我们手里。
**对策。** 退出按 Ctrl-\\。或者从另一个会话 `kill <pid>`（SIGTERM/SIGHUP/SIGINT 都有处理，会走清理）。

### 18. 点击变成了右键，而且什么都拖不动

**根因。** 注入事件上残留了 Control 修饰键。`postKey()` 给 Ctrl 组合键（Ctrl-C、Ctrl-<字母>）发的
事件带 `.maskControl`，而 `CGEvent(mouseEventSource: nil, …)` 会继承**会话的**修饰键状态 —— 于是只要
发过一次 Ctrl 组合键，之后每一次点击都成了 Control+点击，macOS 把它当右键（弹上下文菜单），
拖拽也变成上下文菜单手势，窗口纹丝不动。
**对策。** （0.1.1 已修）`postMouse`/`postScroll` 现在按 SGR 按钮码**显式**设置 `event.flags`，
普通点击不带任何修饰键。如果你在老版本上：用 Ctrl 组合键之后右键和拖拽就废了，重启 krd 并避开 Ctrl。

### 18b. 右键 / 中键 / 双击 / 带修饰键的点击

**根因。** 老版本只映射了按钮 0，也从没设过 `clickState`。
**对策。** （0.1.1 起）按钮位分别映射到 `leftMouse*` / `otherMouse*`（中键）/ `rightMouse*`；
`clickState` 按「半秒内同一位置」推导（双击、三击都能用）；修饰键位 `& 4`/`& 8`/`& 16` 变成
Shift/Option/Control 带到事件上；水平滚轮（`& 64` 且 `& 3` = 2/3）走 `wheel2`。
仍然没有的：跨应用拖拽、力度/压感事件、以及任何输入法（见 19）。

### 19. 打中文/日文没用

**根因。** 没有输入法集成：US/ANSI 表里没有的字符是用 `virtualKey 0` + Unicode 字符串发的，直接绕过了
输入法。
**对策。** 用 ASCII 布局。要支持输入法，得先有 kitty 键盘协议，还得解决候选窗这块终端根本没有的地方。

### 20. 用 `--window` 时，点击打到了最上面的窗口而不是被镜像的那个

**根因。** `--window` 只过滤*采集*；注入是全局的 `CGEvent.post(tap: .cghidEventTap)`，谁在最上面谁来接。
**对策。** 让被镜像的窗口保持在前台，或者等 `CGEventPostToPid`（Roadmap）。

### 21. `KRD_Q=0` 往桌面里打了一堆乱码

**根因。** 协议回复落在 stdin 上，而 stdin 处于 raw 模式、正在被当输入解析；开头那段看起来就是
Alt-`G`，后面全变成文字。
**对策。** `KRD_Q=0` 只配 `--no-input` 用，或者离线看 `KRD_DUMP`。

### 22. 按 F11 或 F12 会让进程直接退出

**根因。**（0.1.2 及更早。）`CSI 23~`/`CSI 24~` 用 `code - 11` 去索引 F 键表，也就是 12 元素数组的第
12、13 项。Swift 越界索引直接 trap，且 trap 无法 catch，`input.restore()` 和 `writer.endSession()` 都
没跑：pane 停在备用屏幕、raw mode 没关，用 `reset` 清掉。
**对策。** `ESC [ <n> ~` 现在是一张 `[Int: CGKeyCode]` 表（`Keys.numbered`，`Input.swift`）：F1–F14 用到的
编号都有行，编号里的空档（16、22）没有行，于是陌生编号直接忽略，任何下标都越不过表尾。`ESC O P–S`
由同一张表生成，F1–F4 的两种写法不可能漂移；解析决策和这张表都由 `Tests/krdTests/InputTests.swift`
钉住。

## 4. ScreenCaptureKit 与权限

### 23. 只来一帧，然后流永远停住

**根因。** 这一代 macOS 上 `SCStreamConfiguration.queueDepth = 1` 会把流卡死：第一帧送到了，之后没有
任何回调，也不打日志。
**对策。** `queueDepth = 3`（`Capture.swift`）。

### 24. 流无声无息地死了

**根因。** `SCStream(delegate: nil)` —— 流可能停掉，却没有任何通知路径。
**对策。** capturer 自己当 delegate 并实现 `stream(_:didStopWithError:)`，会记 `capture stopped: <error>`。
先看日志文件，再判断「画面自己停了」。

### 25. ScreenCaptureKit 只送一帧就没了（而且没有错误）

**根因。** 没有 `NSApplication` 上下文。在被测的 macOS 版本上验证过：没有 AppKit 上下文时流只给一帧，
有了就是完整流。
**对策。** `main.swift` 在其它一切之前创建 `NSApplication.shared` 并
`setActivationPolicy(.accessory)`。`KRD_NO_NSAPP=1` 可以故意复现这个故障。

### 26. `-3801 user declined`，或者重编一次权限就没了

**根因。** TCC 把屏幕录制授权记在**代码签名**上。ad-hoc 签名（`codesign -s -`）每次重编都产生新的 cdhash，
系统看到的是另一个 App，旧授权自然对不上。
**对策。** 装到固定路径、用稳定身份签 —— `install.sh` 默认就是这么做的（或
`KRD_SIGN_IDENTITY="Apple Development: …" ./install.sh`）。identifier `com.kkrt.macdesk` 必须冻住 ——
改它等于新建一条 TCC 记录，得重新授权。

### 27. 画面正常，但点击和按键没反应

**根因。** 辅助功能（事件注入）没授权。`--debug` 会记 `AXIsProcessTrusted()`；采集和注入是两项独立授权。
**对策。** 系统设置 → 隐私与安全性 → 辅助功能 → 用 `+` 加上装好的二进制；或者在目标 Mac 自己的图形界面
终端里跑一次，让 macOS 能弹窗。

### 28. `--list` 什么都不打印 / 直接报错

**根因。** `--list` 走 ScreenCaptureKit 枚举，所以同样需要屏幕录制权限。
**对策。** 把 `--list` 当成第一跑的权限检查：在目标 Mac 自己的图形界面终端里跑，授权，确认它能打印出
显示器和窗口。

### 29. Mac 锁屏或睡眠时画面变黑

**根因。** 锁屏会话不给 ScreenCaptureKit 任何屏幕内容，流还在跑，但帧是黑的/空的。
**对策。** 解锁。不要指望无人值守时还能看到锁屏后的画面；锁屏会话的屏幕共享不是支持的模式。

### 30. `idle` 一直涨，画面就是不更新

**根因。** `CMGetAttachment(sampleBuffer, SCStreamFrameInfo.status, …)` 用 `as? Int` 取会静默失败 ——
实际挂上去的是 `NSNumber`；于是每一个空帧都被当成坏帧，状态也丢了。
**对策。** `as? NSNumber` → `.intValue`（`Capture.swift`）。`idle` = 没有像素缓冲且 status 非 0；
`bad` = 没有像素缓冲且 status 为 0。

## 5. 排查手段

### 31. 一行调试输出就把画面毁了

**根因。** 往 pty 写文字会移动光标；写到最后一行会整屏滚动，而瓦片是按绝对格位贴的，于是画面碎成一片。
**对策。** `Log` 只写文件，永不写 tty（`--debug` → `$TMPDIR/krd-<pid>.log`，`--log <path>` 指定路径）。
永远不要在渲染路径上加 `print()`/`FileHandle.standardOutput` 调试行。

### 32. `screencapture -x` 截出来的不是你想要的

**根因。** `-x` 只截主显示器，多屏要用 `-D <n>`；`-l <windowid>` 对某些 GPUI 渲染的窗口会拿到空白或未合成
的图像。
**对策。** 其它屏用 `-D`；调协议时优先信 krd 自己的 `KRD_DUMP`（真正发出的字节），而不是截图。

### 33. 用颜色判断「画出来了没有」，结论是错的：截图有色彩管理

**根因。** 纯色 `(255,0,255)` 的瓦片经过采集、编码、重新合成之后可能读成 `(243,12,246)`。精确相等在
一台正常工作的机器上就会失败。
**对策。** 每个通道留至少 ±60 的容差。

### 34. ……而且精确颜色匹配已经骗掉过一整轮排查

**根因。** 当时从一次颜色不符得出「瓦片没贴上去」的结论，而那次不符其实只是第 33 条的色彩管理，于是去修
了一个根本不存在的 bug。
**对策。** 永远不要把精确颜色匹配当成「画出来了」的唯一证据。用结构性标记：`KRD_GRID=1` 给每块瓦片画
白边，你要量的是瓦片的*几何*；`KRD_DUMP` 用来看真正发出去了什么。

### 35. 分不清是渲染器坏了还是采集坏了

**根因。** 大多数黑屏报告都是三种可能混在一起：没像素、协议不对、没权限。
**对策。** 把管线切开：`krd --selftest --no-input` 用合成像素跑完整的瓦片/编码/写出路径，完全不需要权限。
selftest 能画出来，说明渲染器没问题，问题在采集或权限；画不出来，问题在终端或协议。然后再用
`KRD_GRID=1`（定位）、`KRD_QUADRANTS=1`（你的终端认哪种发图方式）、`KRD_Q=0`（错误）、`KRD_DUMP`（字节）。
逐个开关的说明见 [TESTING.zh-CN.md](TESTING.zh-CN.md)。

### 36. 走 SSH 时怎么看 krd 的日志

**对策。** 永远显式给路径，省得找：
`ssh -t host ~/bin/krd --fps 20 --debug --log ~/krd.log`，然后在另一个会话里
`ssh host tail -f ~/krd.log`。1 Hz 的 `stats:` 行能告诉你帧到底来没来（`tiles/s 0` 且 `dirty 0` = 没变化
或者没采到；每个字段的含义见 [ARCHITECTURE](ARCHITECTURE.zh-CN.md#9-诊断开关的接线)）。
