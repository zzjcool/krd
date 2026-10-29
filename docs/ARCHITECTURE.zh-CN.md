# 架构

[English](ARCHITECTURE.md) | 简体中文

krd 是一个单文件 Swift 可执行程序，十三个源文件约 3.9 k 行，除了系统框架
（`ScreenCaptureKit`、`CoreGraphics`、`AppKit`、`Accelerate`、`libz`）没有外部依赖。本文说明这些
部件怎么咬合，以及哪些不变量不能碰。

## 1. 设计目标

1. **本地什么都不用装。** 没有客户端、没有端口、没有自己的认证。离开 Mac 的字节必须是合法的终端
   转义流 —— 因为那是唯一可用的通道。
2. **带宽只和变化成正比。** 静止桌面必须零开销；改一个字符必须是 KB 量级。
3. **不留下任何可见的协议痕迹。** 不闪、不出现半张瓦片、光标不乱跑、任何文字都不写到画面上。
4. **能被暴力打断。** `kill -9` 正好落在一次写入中间，也不能把 pane 永久弄坏。

## 2. 源码地图

```
Sources/krd/
  main.swift      参数解析、生命周期、布局应用、统计、resize、selftest
  Geometry.swift  TermGeometry（CSI 16t/14t、TIOCGWINSZ）与 Viewport（格/像素 → 屏幕点）
  Tiles.swift     TileGrid：整格网格、每块瓦片的像素矩形、切片、脏检测
  Capture.swift   Capturer：SCStream 配置、BGRA→RGBA、逐字节相同帧丢弃
  Render.swift    ScreenWriter：会话框架、逐瓦片 kitty 转义、zlib、KRD_DUMP
  Input.swift     InputReader：raw tty、SGR/SGR-Pixels 鼠标、按键 → CGEvent
  Log.swift       文件日志（永不写 tty）
  AXCommand.swift `krd ax …`：预检、应用解析、带预算的树遍历、文本 + JSON
  AXFormat.swift  纯逻辑那一半：消毒、剪枝、单行渲染（有测试覆盖）
```

依赖是单向直线：`main` → `Tiles`/`Capture`/`Render`/`Input` → `Geometry`。只有 `Render` 和 `Input`
懂终端协议，其它模块不懂；只有 `Capture` 懂 ScreenCaptureKit，其它模块不懂。

## 3. 线程

| 工作 | 在哪 |
|---|---|
| `RunLoop.main.run()` | 主线程；`NSApplication` 上下文在这里 |
| 帧回调（`handleFrame`） | `krd.capture` 串行队列，`qos: .userInteractive` |
| stdin 解析 | 一条 detached 线程（`InputReader.loop`） |
| 统计定时器（1 Hz） | 主队列（`DispatchSource.makeTimerSource`） |
| 信号源（`SIGTERM`/`SIGHUP`/`SIGINT`） | 全局队列 → `shutdown()` |
| `SIGWINCH` | 全局队列 → 延迟 50 ms 转主队列 → `handleResize()` |

共享状态（`grid`、`viewport`、`previousFrame`、`lastDirtyCount`）由 `Desk` 里一把 `NSLock` 保护。
`ScreenWriter` 故意不加锁：稳态下它只有一个生产者，就是采集队列。两个例外是输入启动时写
`?1003h/?1002h/?1006h/?1016h`（走静态方法里的直接 `write(2)`，不经过 writer）以及 resize 时的
`writer.clear()`（可能和一帧正在发出的瓦片交错）；最坏情况是多一次整帧重绘。

## 4. 启动

```
NSApplication.shared + setActivationPolicy(.accessory)   （KRD_NO_NSAPP 存在时跳过）
parseArguments()
Desk.run():
  Log.configure(--log / --debug)          → 向 stderr 打一行 "krd: logging to <path>"
  if --selftest:                          → 布局、beginSession、runSelfTest、返回（不碰 SCK，不需 TCC）
  SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
  if --list:                              → 打印显示器/窗口后 exit(0)
  geometry = TermGeometry.query() ?? TermGeometry.read()
  filter + fullRect                       → 一个窗口，或一块显示器
  configureSource(rect)                   → 缩放焦点：--zoom-at，否则指针，否则中心
  applyLayout(geometry)                   → Viewport.crop(full, zoom, focus) → TileGrid + Viewport，previousFrame = []
  writer.beginSession()                   → 自愈、备用屏、归位、隐藏光标
  installSignalCleanup(); installResizeHandler(); if --debug startStats()
  capturer.start(filter:sourceRect:width:height:fps:)  （width/height 来自布局，sourceRect = 裁剪区）
  if !--no-input: InputReader.start()     → raw tty、?1003h ?1002h ?1006h ?1016h
  while true { sleep 1 s }
```

之所以要有 `NSApplication`：在被测的 macOS 版本上，没有 AppKit 上下文时 ScreenCaptureKit 只送一帧，
有上下文才是完整流（`KRD_NO_NSAPP=1` 可复现这个故障）。`.accessory` 让 krd 不出现在 Dock 和
⌘-Tab 里。

## 5. 帧路径

```
SCStream 回调（采集队列）
  └─ Capturer.stream(_:didOutputSampleBuffer:of:)
       ├─ sample attachments：status=complete|idle|blank…  → idle / bad / 真正的帧
       ├─ CVPixelBuffer → vImagePermuteChannels_ARGB8888(BGRA → RGBA)
       └─ previous == rgba ? 丢弃 : 保留   ← 静止桌面在这里就是零成本
          └─ Desk.handleFrame(pixels:width:height:)          （同一队列）
               ├─ 尺寸和布局不符 → 记一次日志后丢弃
               ├─ dirty = TileGrid.dirty(previousFrame, pixels, grid)
               │          （--full-frame 或帧尺寸变化时 = 全部瓦片）
               ├─ writer.beginFrame()   （清空每帧计数）
               ├─ dirty 为空 → writer.nudge() 后返回
               ├─ 在脏瓦片上 concurrentPerform（压缩无状态）：
               │     extract(rect) → zlib(compress2, level = LevelPolicy[瓦片]) → CompressedTile
               └─ 然后串行逐块：writer.emit(tile)（只做转义拼装）
                    CUP → base64 分块 → a=t 传输 → a=p 放置 … writer.endFrame()（?2026l + flush）
```

两级去重是刻意保留的：采集侧比较整帧（`previous == rgba`，Array 相等，底层一次 memcmp）干掉真正
静止的情况；瓦片侧逐块比较，让一个小变化只花一个小更新的钱。也正因为采集侧已经拦住了静止画面，
`dirty.isEmpty` 很少发生 —— 所以 `nudge()`（见 §7）不是每帧开销。

尺寸和当前布局不符的帧会被丢掉并记一条日志
（`krd: dropping frames: got WxH, layout expects WxH`）。这条日志意味着 resize 和流撞了一下，
不是采集坏了。

## 6. 布局算法

`TileGrid.make(geometry:aspect:tileCols:tileRows:)`：

```
cols = geometry.cols
rows = round(cols * cellW / aspect / cellH)        // aspect = sourceRect.width / height
if rows > geometry.rows { rows = geometry.rows
                          cols = round(rows * cellH * aspect / cellW) }
cols = clamp(cols, tileCols, geometry.cols)        // 至少容得下一块瓦片
rows = clamp(rows, tileRows, geometry.rows)
pixelW = max(2, round(cols * cellW))               // SCStream 的输出尺寸
pixelH = max(2, round(rows * cellH))
```

`TileGrid.rect(tx, ty)` 同时给出瓦片的像素矩形和它的放置占位：

```
cx = min(tileCols, paneCols - tx*tileCols)         // 这块瓦片有几格宽（边缘瓦片更小）
cy = min(tileRows, paneRows - ty*tileRows)
x0 = round(tx*tileCols * cellW);  x1 = round((tx*tileCols + cx) * cellW)
y0 = round(ty*tileRows * cellH);  y1 = round((ty*tileRows + cy) * cellH)
→ (x0, y0, max(1,x1-x0), max(1,y1-y0), col: tx*tileCols+1, row: ty*tileRows+1, cols: cx, rows: cy)
```

四舍五入只发生在矩形边界上，所以瓦片正好铺满画面，既不留缝也不重叠；`cols`/`rows` 永远是整数格，
因此任何 placement 都不需要亚格偏移，终端也不需要重采样。

### 缩放：少看一点，但按原密度看

把整个桌面塞进小 pane 是一个**选择**，不是定律：`--zoom <f>` 只显示源区域的 `1/f`，并把 pane 映射到
这块裁剪区。60x24 的 pane 在 `--zoom 2` 下是 1.35 px/pt，而不是 0.67（1512x982 pt 屏幕、1020x792 px
pane 的实测值，见 `--debug` 那行）。

```
fullRect   = 显示器 bounds，或 --window 的窗口 frame
focus      = --zoom-at x,y  |  指针（若在 fullRect 内）  |  中心
sourceRect = Viewport.crop(full: fullRect, scale: zoom, focus: focus)      // 始终 clamp 在 fullRect 内
pixelW/H   = pane 的像素数，不变          // 变小的是**源**，不是输出
```

三个值得知道的后果：

1. **裁剪发生在采集端**（`SCStreamConfiguration.sourceRect`，macOS 14+），所以放大后每帧拷贝的像素
   比「整屏塞进 pane」更少，没有任何 CPU 放大。
2. **交互只会更准，而且输入代码一行没改。** `Viewport.point(forCell:)` / `point(forPixel:)` 本来就按
   `sourceRect` 归一化，裁剪区一变，点击就自动落在正确位置：`--zoom 2` 下一个格子覆盖的桌面点少一半。
3. **输出尺寸仍是 pane 尺寸。** 「放大后采集尺寸减半」说的是以 pt 计的源矩形；`pixelW`/`pixelH` 是终端
   能显示的像素数，不会跟着变。Retina 上超过约 2.7x 后，pane 的像素比裁剪区的点还多，画面会被轻微放大
   —— 真正的 1:1 密度在 `屏幕像素 / pane 像素` 处到达，不在无穷远。

`--zoom-follow` 在指针进入画面外圈 15% 时平移裁剪区，而且只平移到刚好把指针放回那条边上（平移，不是追着
跑）。平移会重启采集流：裁剪区是采集端设置，重启会清空 `previousFrame`（一次全屏重绘）并付出一次
`capturer.stop()`/`start()` 的往返。这就是「不每帧付全屏代价」的代价；`KRD_ZOOM_GLOBAL_RECT=1` 的存在
是因为副屏上的 display filter 可能想要全局坐标而不是相对 filter 的坐标。


所有实测数据用的那套配置：

```
显示器  1920 × 1200 pt            aspect 1.6
pane    137 × 73 格               单元格 17 × 33 px
布局    cols 137, rows round(137*17/1.6/33) = 44     → 画面 137 × 44 格
像素    round(137*17) × round(44*33) = 2329 × 1452 px
瓦片    9 × 6 = 54 块，每块 16 × 8 格   （一块 = 272 × 264 px = 287 KB 原始 RGBA）
边缘    tile (8,5)：列 129..137（9 格），行 41..44（4 格）→ 153 × 132 px
```

`--tile c x r` 只改切法，不改画面：同一张 2329×1452 px 的帧被切得不一样而已。瓦片更小意味着每次
更新要发更多转义（每块瓦片固定约 120 字节控制字 + 一次 flush），单次变化的最坏延迟更小；瓦片更大
意味着更少、更大的更新。

## 7. 渲染不变量

这些不是风格选择，每一条都修掉了一类具体故障。逐字节的细节见 [PROTOCOL.zh-CN.md](PROTOCOL.zh-CN.md)。

1. **每块瓦片一个 image id + 一个 placement id，进程生命周期内固定**（`100+index`、`1000+index`）。
   新一帧只是覆盖同一块瓦片的上一个 placement。**永远不对单块瓦片发删除**，所以哪个终端把 `a=d`
   实现得再离谱也伤不到我们。
2. **绝不往 tty 写文字。** `Log` 只写文件。一行诊断就会移动一次光标；写到最后一行会整屏滚动，而每块
   瓦片都是按绝对单元格贴的，屏幕一滚画面就碎成片。（`--debug` 写文件就是为了这个。）
3. **每个 placement 都带 `C=1`** —— 贴图不能移动光标，否则终端会把它推进画面（甚至推过最后一行），
   后续定位要么漂移要么触发滚动。
4. **每块瓦片自带一个 `?2026h … ?2026l` 块**（`KRD_NOSYNC=1` 可去掉），这样终端只可能看到旧的
   placement 或新的 placement，看不到半张图。
5. **`nudge()`**（`ESC[?25l`）只在一帧采到了、但没有任何脏瓦片时发：有的终端要等到下一次输出周期
   才提交 placement，这一字节让管道继续走，顺便再次确认光标隐藏。
6. **进入时自愈。** `beginSession()` 以 `ESC \`（补上被前一个被杀进程留下的 APC 结束符，否则它会吞掉
   之后所有字节）+ `?2026l`（补上没结束的同步块）+ `?1003l ?1002l ?1006l` + `ESC[0m` + `?25h` 开头，然后切
   备用屏。
7. **显式收尾。** `endSession()`：`ESC \` + `?2026l` → 删掉全部 placement（`a=d,d=a`）+ `2J` →
   `?1003l ?1002l ?1006l ?25h ?1049l`。

## 8. resize 与退出

`SIGWINCH` → 等 50 ms（终端更新 `winsize` 是异步的）→ `handleResize()`：用 `TermGeometry.read()`
重新测量、重建布局、`writer.clear()`、按新的像素尺寸重启流。注意这条路径只用 `read()`（不做 CSI
查询），所以在不汇报像素尺寸的 pty 上它会退到 `--cell`。

退出（`SIGTERM`、`SIGHUP`、`SIGINT`、Ctrl-\\，或 `run()` 抛错）是幂等的（`cleanedUp` 标志）：
恢复 termios → `endSession()` → `exit(0)`。`kill -9` 不会走到这里，所以才有 §7.6。

## 9. 诊断开关的接线

| 开关 | 代码路径 |
|---|---|
| `--debug` | `Log.configure` + `startStats()` + `reader.trace` + 几何/辅助功能那几行日志 |
| `--log <path>` | 只有 `Log.configure`（没有统计，没有输入轨迹） |
| `--dry-run` | `InputReader(dryRun:)`：解析并记日志，绝不调用 `CGEvent.post` |
| `--zoom <f>` | `applyLayout` → `Viewport.crop`；`Capturer.start(sourceRect:)` 在采集端裁剪 |
| `--zoom-at <x,y>` | `configureSource`：裁剪区的中心，全局屏幕点 |
| `--zoom-follow` | `followPointerIfNeeded`：指针进入 15% 外圈时平移裁剪区，然后重启采集流 |
| `--selftest` | `runSelfTest(layout:)`：合成帧（按当前 `--format`）走真正的 `handleFrame`/`emit` |
| `KRD_DUMP` | `ScreenWriter.flush` 把每次 flush 的缓冲同时写一份到文件 |
| `KRD_Q` | 每条转义里的 `q=` 字段（默认 `2` = 静默） |
| `KRD_FORMAT` | `rgb`（默认，`f=24`）或 `rgba`（`f=32`） |
| `KRD_SYNC` | `tile` 恢复每瓦片一个同步块；`KRD_NOSYNC=1` 完全关掉 |
| `KRD_REAP` | 每 n 帧整屏重绘（0 = 关闭，默认） |
| `KRD_BENCH_BUDGET_SCALE` | 只给 `bench/bench.py` 用（krd 本身不读）：按机器速度倍数放大 `ms.*` / `write_ms.*` 预算，bytes 永不放宽（见 [BENCHMARK](BENCHMARK.md) §6） |

1 Hz 的统计行就是 `Desk.startStats()` 里一次 `String(format:)`：

```
stats: <瓦片/秒> tiles/s  <脏块数> dirty  <KB> KB  <MB/s>  ms[zlib=<ms> write=<ms>]  <WxH> px <CxR> cells  cap=<delivered>/<skipped>/<callbacks> idle=<n> bad=<n>
```

`tiles/s` 是 `framesEmitted` 的增量（数的是瓦片，不是帧）；`KB` 是最近一帧压缩后的负载；`MB/s` 是最近
一秒写出的字节；`idle`/`bad` 是没有像素缓冲的 ScreenCaptureKit 帧，按 sample attachments 里的
status 区分（`idle` = 状态这么说或者根本没有状态，`bad` = 它声称 `complete`）。

## 10. 扩展点

- **剪贴板** —— 入口是 `InputReader`（OSC 52 入）和 `ScreenWriter`（OSC 52 出）；除了「不写文字」这条，
  渲染路径并不假设这条流只能是图像。
- **换编码器** —— `ScreenWriter.compress`/`emit` 是唯一知道负载格式的地方；`--full-frame` 已经演示了在同一套
  会话框架里走第二条路径。

## 11. 已知的粗糙处

写下来是为了让后来的人不去追鬼：

- 两个抓帧缓冲只有在「帧真的被发出去」时才能省掉复制。被整帧去重丢掉的帧会让 `previous`
  指回即将被重写的那个缓冲，所以下一次真正发出的帧要多付一次 13.5 MB 复制，之后轮转才重新对齐。
- `TileGrid.bpp` 在算布局时从 writer 取；如果哪天支持中途换 `--format`，网格和它对应的
  `previousFrame` 都会失效。
- `LevelPolicy` 每块瓦片从 level 5 起步，需要一帧才能学到；改窗口大小之后所有瓦片重新学，
  表现为第一帧略大。
- `Capturer.format` 必须在 `start()` 之前设置；它是普通 `var` 而不是构造参数，因为 `Desk`
  先建 writer 再建 capturer。
- `KRD_QUADRANTS` / `KRD_DELTEST` / `KRD_GRID` 这几个自检开关仍然在描述「终端会忽略 `a=d`」
  的世界。它们作为标定工具保留，尽管线上路径从不删除。
