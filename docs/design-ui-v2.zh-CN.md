# krd 交互界面 v2：基于 libghostty 的可点击 TUI（方案）

**状态：** 已定稿，按 P0 开工（2026-10-31）。用户把三个待定问题全权交给实现方，§10 记下了每一条怎么定的、为什么。
**基线：** `main` @ `0241541`（含 #162 解析终端应答、#169 wall 触发器）。下文 `path:line` 都指这个提交。
**一句话：** 界面本身跑在远端 Mac 上，SSH 管道只运送「变了的格子」。libghostty-vt 在 krd 里不是用来画屏的，
而是当**参考终端**：算宽度、做无头渲染测试、量每次 UI 更新要多少字节。所有新能力都先探测，探不到就退回
今天的样子。

本文的数字都是实测：Rex（内置 libghostty）在本机跑一次、经 `ssh -t krd-vm` 跑一次，Ghostty 1.4.0 在 VM 里
跑一次（像素结论来自 VM 屏幕截图）。探针是 `probe/termcaps.py` 和 `probe/placeholder_overlay.py`，复现方法见 §9。

---

## 1. 今天的界面（出发点）

| 页面 | 现在长什么样 | 能点什么 |
|---|---|---|
| wall（落地页） | `▪ krd  5 windows · 1 displays` 表头，屏幕舞台，`──` 分隔线，`▣ recent 1–3 / 5 ⤢ 3` 卡片区，右侧 `╷ │ █ ▲ ▼ ╵` 滚动条，页脚提示 | 舞台、卡片、`⤢ N`、滚动条、滚轮 |
| mirror 顶栏 | 一行反显：`● ● ●` + 标题 + `4 fps · 0.0 MB/s` + 时钟 + `[ - ]` | 只有 `[ - ]`/红点（缩回 wall） |
| `--dev` 状态栏和面板 | 状态行 + stats/devices/settings/log/help 面板 | 状态段可点开面板，面板内**全部吞掉** |
| 加载卡 | 36×18 `▀` 真彩寄居蟹，110 ms 一帧 | 无 |

现有代码里卡住新 UI 的几处：

- **配色只有 16 色 SGR**：`Chrome.Style.sgr` 用 `2;37 / 1;97 / 36 / 33 / 31 / 7`
  （`Sources/krd/Chrome.swift:282-292`），wall 也用这张表（`WallCanvas.swift:345`）。终端主题是什么颜色，
  界面就是什么颜色，没有设计感。
- **点击模型是「一行文字段」**：`ChromeHit`（`Chrome.swift:232`）只有 `statusSegment / insidePanel / outside`。
  面板里点了没用，没有 hover，没有按下态，没有拖动（#87 的滑块没地方落）。
- **wall 收到的移动事件全扔掉**：`Input.swift:477/510/521` 只把非 motion 的按下交给 `onChromeClick`，所以 hover 没法做。
- **wall 的文字层不包同步输出**：`paintWall` 先 `writer.writeChrome(text)`（`main.swift:1912`，写完立刻 flush），
  再 `beginFrame()`（`:1917`）发图。`writeChrome`（`Render.swift:1019-1025`）不看 `batchOpen`，
  所以一次重绘在终端上是**两次**更新（尤其经 SSH 分包时）。mirror 的 `drawChrome`（`main.swift:3820`）同理。
- **宽度表是自己维护的**：`DisplayWidth`（`TextWidth.swift`），和终端实测有两处不一致（§2.3）。
- **启动探测串行**：wall 首图前三个探测串着跑，600 + 500 + 600 ms（`main.swift:1031`、`:1451`、`:1468`，#99 实测 1758 ms）。

已有、可以直接复用的好底子：格子级 diff（`WallCanvas.render` 只写变了的格子）、`?2026` 帧同步
（mirror 路径）、`U=1` 占位符（图像随格子走，终端负责缩放）、RTT 探针（`RTTProbe`）、两个 governor、
#162 之后的应答解析（kitty 图形应答、DSR、kitty 键盘标志都不会再被当成按键）。

## 2. 实测：终端（libghostty）到底能给什么

### 2.1 能力：Rex 与 Ghostty 1.4.0

Rex 本机和 `ssh -t krd-vm` 的回答**逐字节相同**（颜色除外：同样从 `rex window new` 开出来的窗口，有的回
`#e6edf3`/`#0d1117`，有的回 `#d9d4c8`/`#131320`）。**配色必须每次启动都问，不能假设。**

| 能力 | Rex（经 SSH） | Ghostty 1.4.0（VM） | 对 UI 的意义 |
|---|---|---|---|
| 身份 | DA1 `?62;22c`，DA2 `>1;0;0c`，XTVERSION `rex 0.0.1793299046` | DA1 `?62;22;52c`，DA2 `>1;10;0c`，`ghostty 1.4.0` | 按能力探测，不按名字 |
| kitty 图形 | `a=q` OK，`U=1` OK，`a=f` OK（`r=2`） | 同左 | 图标/徽章/动画下发一次、终端本地播放 |
| 鼠标 | DECRQM 1000/1002/1003/1006/1016 全部 2 | 同左 | 像素坐标：滑块可以做到亚格精度 |
| 焦点 1004、粘贴 2004、同步 2026 | 支持 | 支持 | 失焦降帧（#110），整帧原子提交 |
| **2027 字素簇** | 支持，**默认关**（2） | 支持，**默认开**（1） | 两个终端起点相反，见 §2.3 和 §7 |
| 2031 配色方案通知 | `?996n` 回 `?997;1n`（深色） | 回 `?997;2n`（浅色，VM 是浅色外观） | 跟随终端深浅主题，不用轮询 |
| 2033 可见性报告 | 一打开立刻回 `CSI ?999;1n` | 同左 | 窗口被遮住时图像流可以停 |
| 2048 带内尺寸 | 一打开立刻回 `CSI 48;24;80;384;640t` | 回 `CSI 48;35;99;595;792t` | 尺寸变化走数据流，不靠 SIGWINCH + 再查 16t/14t |
| kitty 键盘 | 默认 `0`，push 11 后回 `?11u` | 同左 | 松开事件、消歧 |
| OSC 10/11/12/4 | 回 `rgb:…` | 回 `rgb:…` | 从终端前景/背景**派生**界面配色 |
| 下划线 | DECRQSS 回 `0;4:3m` | 同左 | 链接、悬停、错误下划线样式 |
| OSC 8 链接 | Rex 的 HTML 导出里是 `<a href>` | 支持 | 「打开日志」「打开 issue」直接可点 |
| REP（`CSI b`） | 支持 | 支持 | 长横线/填充只要 4 字节 |
| OSC 22 指针形状 | 解析，形状**未能确认** | **实测生效**（§2.5） | 「这能点」的零格子提示 |
| OSC 66 文字缩放 | 不支持 | 不支持 | 不用 |

结论：**这台终端能给的远比 krd 用到的多**。krd 现在用了 2026、1002/1003/1006/1016、U=1、16t/14t、kitty 键盘、OSC 52、DSR；
2027、2031、2033、2048、1004、OSC 8、OSC 22、OSC 10/11、`a=f` 都没用（`grep -rn 2027 Sources` 为空）。

### 2.2 延迟：真正的约束在 SSH 客户端

`DSR 5n → 0n` 往返，40 次采样（ms）。同一台 VM，只改 `ObscureKeystrokeTiming`：

| 路径 | min | p50 | p90 | max | 20 个查询逐个问 | 20 个查询一次写完 |
|---|---:|---:|---:|---:|---:|---:|
| 本机 Rex | 0.05 | 0.09 | 0.17 | 0.71 | 0.9 | 0.1 |
| `ssh`，`interval:5` | 0.70 | 5.79 | 18.5 | 26.3 | 162 | 0.5 |
| `ssh`，默认（= `interval:20`） | 0.71–0.81 | **21.2–23.5** | 35.6–36.4 | 44–45 | **488–534** | 17.7–34.2 |
| `ssh`，`interval:80` | 27.7 | 65.9 | 77.9 | 88.4 | 1724 | 0.9 |
| `ssh -o ObscureKeystrokeTiming=no` | 0.37–0.39 | **0.59–0.60** | 0.74–16.6 | 27.5–33.1 | 6.5–19.5 | 0.9–5.8 |

1. **p50 随间隔线性走**（5 → 5.8 ms，20 → 21–24 ms，80 → 66 ms）。这是 OpenSSH 10 的 `ObscureKeystrokeTiming`：
   客户端把**上行**字节（按键、鼠标报告、终端应答都是）攒到 18–22 ms 一拍再发，停手后还会发 1–3 s 假包
   （`clientloop.c:556-559`、`:629-672`，V_10_3_P1；`readconf.h:234-236`）。下行（画面）不受影响。
   关掉以后 p50 从 23.5 ms 降到 0.59 ms，**快 40 倍**。仓库文档里一个字都没提（`grep -ri ObscureKeystroke docs` 为空）。
   krd 改不了用户的 ssh 客户端，能做的是**测出来、告诉用户**（§5.3），并在排障文档里给出 `Host` 配置。
2. **逐个查询 vs 一次写完：488–534 ms vs 18–34 ms**。启动时所有探测必须一次写出、用 DA1 收尾（#99）。
3. **一次离群就会让 governor 降一档（已核实，见 §7.1）。** 两轮共 80 个采样里出现过一次 258 ms。

### 2.3 宽度：开 2027 之后，libghostty 和两个终端一致；krd 自己的表不一致

光标实测（打印后 `CSI 6n`，先显式 `?2027l` 再 `?2027h`），krd 的 `DisplayWidth`，libghostty v1.4.0 的 `ghostty_unicode_grapheme_width`。
Rex 和 Ghostty 1.4.0 在两种模式下**逐字形相同**（34 个字形），所以合成一列：

| 字形 | 关 2027 | 开 2027 | krd `DisplayWidth` | libghostty（2027） |
|---|---:|---:|---:|---:|
| `🖥️`（U+1F5A5 + VS16） | 1 | 2 | 2 | 2 |
| `☰`（U+2630，菜单图标） | **2** | **2** | **1** ✗ | 2 |
| `⚙️`（+VS16）、`❤️` | 1 | 2 | 2 | 2 |
| `👍🏽` | 4 | 2 | 2 | 2 |
| 👨‍👩‍👧 ZWJ | 6 | 2 | 2 | 2 |
| `🇨🇳` 国旗 | 4 | 2 | **1** ✗ | 2 |
| krd 现在画的和计划要画的 27 个字形（`▪ 🖥 ▣ ▲ ▼ ⬅ ⤢ ⤡ · × — – ● ↕ → ╭ ▀ ↺ ▸ …`、Nerd PUA、八分块、octant） | 1 | 1 | 1 | 1 |
| 平假名 `あ` | 2 | 2 | 2 | 2 |

- krd 有两个字形算错（`☰` 和国旗），**两种模式下都错**。窗口标题里有国旗 emoji，就会让一整行错位。
- 不开 2027 时终端的宽度很「原始」（ZWJ 记 6 格），krd 却按开了 2027 来算。**解决办法：会话里开 `?2027h`，
  用 libghostty 的同一个函数算宽度。**
- 两个终端的**默认值相反**：Ghostty 1.4.0 默认开着 2027（DECRQM 1），Rex 默认关（2）。所以「什么都不发」
  在两个终端上宽度不一样，必须探测，退出时也必须恢复原值（§7）。
- `?2027h` 不改占位符的格数：一行 10 个 `U+10EEEE`（krd 的写法：首格带行号变音符，其余裸写；或每格都带行列变音符），
  两个终端、两种模式下光标都落在第 11 列（`/tmp/krd-capprobe/ph2027.py`，见 §9）。

### 2.4 字节：哪里贵，哪里便宜

拿 `script` 录下 VM 上 krd 输出的原始字节：

| 内容 | 字节 | 占比 |
|---|---:|---:|
| wall 首屏总计（80×24，1 个显示器 + 3 张卡） | 178,855 | 100 % |
| ├ kitty 图像（55 条 APC，base64 169,704 B） | 170,578 | 95.4 % |
| ├ 占位符格子（698 格 × 4.1 B） | 2,842 | 1.6 % |
| └ 文字、SGR（190 条）、CUP（118 条）、其他 | 5,435 | 3.0 % |
| 加载卡**一帧**（648 个 `▀`，每格都带完整 24 位前景+背景色，另有每行 CUP/EL） | ≥ 21,202 | — |
| 加载卡持续开销（110 ms 一帧） | **约 188 KiB/s** | — |
| 一次 chrome 更新（112 B）喂给 libghostty 的耗时 | 0.31 µs | — |

结论：**文字界面几乎不花字节**（一屏不到 6 KB，diff 后一次点击几百字节）。贵的是图像（截图），还有那张加载卡：
它在等首帧时自己就要占 188 KiB/s，和要等的那张图抢同一条管道。

### 2.5 像素实测（Ghostty 1.4.0，VM 屏幕截图）

`probe/placeholder_overlay.py` 画一张 40×12 格的纯品红 `U=1` 图，然后在图上盖三块文字/空白，再把其中一块
写回占位符。截图后数每块里品红像素的占比（1.0 = 图还在，0.0 = 被盖住）：

| 区块 | 写了什么 | 盖上以后 | 写回占位符以后 |
|---|---|---:|---:|
| A | 深色底 + 文字（第 4 行，第 8 列起，19 格） | 0.0 | **1.0** |
| B | 只有底色的空格 | 0.0 | 0.0（没写回） |
| C | 默认底色的空格 | 0.0 | 0.0（没写回） |
| 对照 | 没动 | 1.0 | 1.0 |

- **浮层可以直接画在 `U=1` 画面上**：文字、带底色的空格、默认底色的空格都会把图盖住（三次运行一致）。
- **关闭浮层只要把占位符写回去**：不重发图像，图就回来了。这正是 §4.2 的浮层方案。

OSC 22 指针形状（`warp` 发 mouseMoved 事件，`screencapture -C` 连指针一起截）：

| 时刻 | 指针 |
|---|---|
| 发 `OSC 22;pointer` 之前，鼠标停在图上 | I 形（`text`，Ghostty 初始形状） |
| 发了之后，鼠标**没动** | **手形** |
| 再动一下 | 手形 |
| 开着 `?1003h ?1006h` 时发 `OSC 22;pointer` | 箭头 → 手形 |
| 鼠标在窗口外 | 箭头，不受影响 |

- **形状立刻生效，不需要再动鼠标**（源码上看不出来，Ghostty 只改了 `NSScrollView.documentCursor`，
  `SurfaceScrollView.swift:146-150`，这条靠实测才确认）。
- **开/关鼠标模式会冲掉形状**：打开 1000/1002/1003 会把形状设成 `default`，关掉设成 `text`
  （`src/termio/stream_handler.zig:765-801`）。所以 **krd 每次切鼠标模式之后都要重发 OSC 22**。
- macOS 版只认 15 种形状（`SurfaceView_AppKit.swift:509-561`）：`default text pointer grab grabbing`、
  四向和两向 resize、`vertical-text context-menu crosshair not-allowed`。`col-resize`、`wait`、`progress`
  等**静默忽略**。滑块要用 `ew-resize`，不能用 `col-resize`。
- RIS（`ESC c`）把形状复位成 `text`。DECSTR、`?1049l`、子进程退出、焦点变化**都不复位**
  （`stream_handler.zig:930-935`；scout 逐条查过）。krd 退出时必须自己发 `OSC 22;` 复位（空值 = reset）。
- 没有查询形式：`OSC 22;?__current__` 只会被当成未知名字丢掉，不回任何东西。不要等它的回复。
- Rex：Rex 内置的 libghostty 带 `GhosttyMouseShape` 和 `MOUSE_SHAPE` 数据项（`strings` 可见），
  序列被解析掉没有显示成文字，但 Rex 没有截屏或报告指针形状的 API（`rex api list` 73 个方法里没有），
  是否真的换了形状**待用户肉眼确认**。

## 3. 方案的核心：三层渲染，界面跑在远端

```
          远端 Mac（krd 进程）                                本地（Rex / Ghostty / kitty）
┌──────────────────────────────────────┐   SSH 字节流   ┌──────────────────────────────┐
│ ① 文字 UI 层：Cell 网格 + 主题 + 组件  │──── 只发 diff ───▶│ 格子渲染（文字、方块、线框）  │
│    hover / pressed / focus 状态机     │                  │                              │
│ ② 图标/装饰层：kitty 图像，按内容哈希  │──── 发一次 ──────▶│ 缓存在终端，U=1 跟格子走      │
│    缓存（圆角、阴影、图标、徽章）       │                  │ a=f 动画在终端本地播放        │
│ ③ 画面层：现有的 tile/governor 路径    │──── 受管控 ──────▶│                              │
│ libghostty-vt：宽度 / 无头渲染 / 测试 │                  │                              │
└──────────────────────────────────────┘◀─── 鼠标/键/报告 ──┴──────────────────────────────┘
```

为什么不是「本地跑一个 UI 客户端」：krd 的卖点就是「SSH 进去敲一个命令」，什么都不用装。
本地客户端是另一个产品（§8 的「不做」）。

### 3.1 libghostty 在 krd 里管什么

`libghostty-vt` 是一个**终端模拟器库**（解析 VT 字节、维护屏幕、编码键鼠），不是 TUI 框架。在远端程序里，
它最有用的三件事：

1. **宽度的唯一来源**：`ghostty_unicode_grapheme_width`（开 2027）/ `ghostty_unicode_codepoint_width`
   （不开）代替 `DisplayWidth` 的手写表。和终端用同一份 Unicode 数据，§2.3 的错位就没了。
2. **无头参考终端**：把 krd 要写出去的字节喂给 `ghostty_terminal_vt_write`，再用 formatter 读屏
   （纯文本/VT/HTML），用 kitty graphics 迭代器读出图像放在哪里，用 `ghostty_terminal_get(…, GHOSTTY_TERMINAL_DATA_MOUSE_SHAPE)`
   （`include/ghostty/vt/terminal.h:3197`）读出 OSC 22 设的指针形状。界面测试从「断言字节」升级到
   「断言屏幕」：按钮在不在第 3 行第 10 列、占位符框对不对、悬停时指针是不是手形。
   一次 112 B 的更新只要 0.31 µs，放进 CI 跑上千个尺寸都没压力。
3. **字节预算尺子**：同一批测试顺带量出每个动作（hover、点开菜单、拖滑块）要发多少字节，写成测试里的阈值。

**不用它做的事：** krd 不是终端，不需要它的 key/mouse **编码器**（那是给终端用的，把按键变成字节）；
krd 要的是**解码**终端发来的报告，这部分 `krdcore/Input.swift` 已经有，而且有 trace fixture 钉住。

### 3.2 已验证：v1.4.0 能直接链进 Swift 包

- 上游最新：`v1.4.0`（2026-10-27，tag 提交 `83fb956`），`main` 比它多 71 个提交。herdr 里那份 vendored 版本比 v1.4.0
  **落后 698 个提交**，不要从那里拿。
- 需要 Zig **0.17.0**（Homebrew stable 正好是 0.17.0）。
  `zig build -Demit-lib-vt -Doptimize=ReleaseFast` 在这台 Mac 上**143 秒**编完（含下载依赖），产出：
  `libghostty-vt.a`（12 MB）、`libghostty-vt.0.1.0.dylib`（2.1 MB），以及
  **`ghostty-vt.xcframework`**（macOS arm64+x86_64，静态库 25 MB 胖包）。
- 上游自带 `example/swift-vt-xcframework`：SwiftPM `binaryTarget` + `import GhosttyVt`。照着写的 spike 小包
  **4.5 秒**编完，宽度和无头渲染都能跑（结果在 §2.3）。链接 `-dead_strip`
  后的体积增量：**只用宽度函数 +86 KB**（空程序 52 KB → 140 KB）；用到终端 + formatter 的完整
  无头渲染程序一共 1.43 MB（只在测试里用，不进 krd 二进制）。krd 现在 1.8 MB。
- SwiftPM 的本地 `binaryTarget(path:)` 必须是**相对路径**（绝对路径报 `invalid local path`）。
- 许可证：MIT，和 krd 相同。

**怎么引入（已定，§10）：** 不在用户机器上编 Zig。CI（或维护者）用固定的 tag + Zig 版本编好 xcframework，
作为 release asset 发布，`Package.swift` 用 `.binaryTarget(url:checksum:)` 引用。`install.sh --from-source`
和 `deploy-vm.sh` 照常 `swift build`，不需要 Zig。krdcore 里保留一个**从 libghostty 生成并提交**的宽度表作为回退，
`swift test` 不依赖二进制也能跑。

## 4. 交互设计：点得到、看得清、什么都不用记

### 4.1 统一的组件和命中模型

把 `ChromeHit` 的「一行文字段」换成 **控件树**：每个控件是一个格子矩形 + id + 状态
（normal / hover / pressed / focused / disabled）。

- **命中测试**：mouse 报告 → 格子坐标（像素坐标来自 1016，滑块用像素做亚格精度）→ 最上层控件。
- **鼠标模式按需开**：wall 和浮层里，没有可 hover 的东西时只开 1000/1002（按下/拖动），鼠标停在可点的
  东西上才需要 1003 的移动事件（mirror 本来就要 1003 把指针转发给远端桌面）。移动事件都是**上行**字节（每次约 10 B）。
  注意上行字节受 `ObscureKeystrokeTiming` 节拍限制（§2.2）：hover 反馈最快也要等一拍（约 20 ms），所以 hover
  动画不要做成逐帧跟手，状态切换一次到位。
- **hover 只重绘两个控件**：离开的那个和进来的那个，各十几个格子、几百字节。
- **OSC 22 指针形状**（§2.5 实测）：可以点的东西 `pointer`（手形），滑块 `ew-resize`，文本 `text`，其余 `default`。
  只用 macOS Ghostty 认得的 15 种。**每次切鼠标模式后重发一次**；形状没变就不发（Ghostty 自己也去重）；
  退出和 heal 时发 `OSC 22;` 复位。
- **键盘可达**：Tab/Shift-Tab 在控件间移动焦点，Enter/Space 触发。krd 是「鼠标优先」，但不是「只有鼠标」。

### 4.2 页面

**wall（落地页）**
- 表头：左边寄居蟹小标 + `krd`，右边链路状态胶囊（§5.3）和 `☰` 菜单按钮（2 格宽，§2.3）。
- 卡片：圆角框（`╭╮╰╯`，Ghostty 的 sprite 字体会画成像素级精确的圆角），悬停时边框高亮 + 标题加亮，
  卡片底部浮出「打开 / 只看 / 置顶」三个小按钮。
- 滚动条：保持右侧，滑块可拖动（今天只能点上下箭头和槽）。
- 空状态/错误：今天是一句页脚，改成居中的卡片，带一个可点的修复动作（「打开系统设置 > 屏幕录制」这种
  可以做成 OSC 8 链接，或者直接在远端执行）。

**mirror 顶栏（解决 #87）**
- `● ● ●  Safari — Apple   ▸ 38 ms · 20 fps · 1.2 MB/s   ☰  ⤡`
- 延迟就是 `RTTProbe` 已经量出来的那个数（p50，不是最近一次）。`—` 表示终端不回 DSR，不显示 `0`。
- `☰` 打开**快速设置浮层**，三根滑块：**画质**（quality 100/90/80/70/50）、**清晰度**（scale 1/0.5/0.25）、
  **帧率**（20/15/10/5）。每根滑块右边一个「自动」开关：
  - 自动开着：滑块显示 governor 当前的档位，不能拖（带一个「自动」小标签）；
  - 拖一下：自动关掉、数值固定（就是今天 `--quality 80` 的语义），旁边出现「↺ 自动」可以点回去。
  这样回答了 #87 的「拖完自己跑回去」问题：**拖就是固定**，并且明明白白显示出来。
- 浮层是 chrome 层的格子，**浮层下面的画面一个 tile 都不重发**。§2.5 已实测：浮层写文字就把 `U=1` 的图盖掉，
  关闭时把占位符写回去（每格约 4 B，40×10 的浮层约 1.6 KB），图像本身不动。
  不走 `U=1` 的路径（像素放置 `a=p` + `c/r`）图像会盖在文字上，浮层打开期间要暂停该区域的 tile，关闭时补发。

**`--dev` 面板**
- 统计面板改成小卡片 + sparkline（`▁▂▃▄▅▆▇█`，一格一个点，每秒一次更新约 100 B）。
- 面板可滚动（#118 已合），面板里的行可以点（复制值、切换开关）。

### 4.3 视觉

- **配色从终端派生**：启动时一次性批量查询 OSC 10/11（前景/背景），在这两个颜色之间插值出表面层
  （surface 1/2/3）、边框、弱化文字。强调色用品牌蓝 `#5EB8FF`，按背景亮度检查对比度，不够就调（对比度/亮度计算
  libghostty 有 `ghostty_color_contrast`/`ghostty_color_luminance`）。所有颜色是 24 位真彩，但每帧只发 diff，
  多出来的 SGR 字节可忽略（§2.4）。
- **2031 跟随深浅色**：终端切主题，krd 收到 `CSI ?997;1n/2n`，重新派生一套配色，整屏重绘一次（文字层，约 5 KB）。
  注意 `CSI ?997;Nn` 以 `n` 结尾，今天的解析器会把它当成 DSR 应答（`krdcore/Input.swift:788-793` 不看参数），
  会被记成一次 RTT 回包。开 2031 之前必须先在解析器里区分 `CSI 0n` 和 `CSI ?997;Nn`。
- **字形**：只用 `box drawing`、`block elements`、`geometric shapes` 和 U+1CD00 octant 这些
  Ghostty sprite 字体**自己画**的字符（不依赖用户装字体，宽度 1；终端若把 East-Asian-Ambiguous 设成 2 格，
  用已有的 `--symbols ascii`）。Nerd Font 图标不能保证存在
  （Ghostty 自带 Symbols Nerd Font，Rex 也打包了，但 kitty/WezTerm 不一定），只作为可选增强，要先探测。
  `☰` 宽度 2，排版时必须按 2 算（§2.3）。
- **图标走 kitty 图像，不走字体**：设置/关闭/展开这类两格宽的图标用 `a=t` 传一次（压缩后几百字节到 1–2 KB），按内容哈希缓存，
  用 `U=1` 放在格子上。圆角卡片的阴影、带圆角的按钮底色同理。只要一次传输，之后零成本。

## 5. 性能：把 SSH 当作一等约束

### 5.1 预算（写成测试）

| 动作 | 目标字节 | 做法 |
|---|---:|---|
| hover 进/出一个控件 | < 600 B | 只重绘两个控件 |
| 打开/关闭菜单浮层 | < 6 KB | 文字层，画面不动；关闭时写回占位符 |
| 拖滑块（每帧） | < 300 B | 只重绘滑块和数值 |
| 主题切换 | < 8 KB | 整屏文字层重绘 |
| 首屏文字（80×24） | < 8 KB | 先画文字骨架，图像后到 |
| 加载动画 | **< 4 KB/s**（今天 188 KiB/s） | kitty `a=f` 动画，或每帧只发变化的格子 |

### 5.2 管道纪律

- **UI 在帧之间插队**：今天 chrome 和 tile 共用 `ScreenWriter` 的一把锁，`writeChrome` 还会在 capture 队列
  写到一半的帧中间 flush（`Render.swift:1044-1049` 的注释承认这一点）。已经写进 sshd 缓冲的字节没法重排，
  做法是：把排队中的 UI diff 放在**下一个** tile 帧前面（仍在 `?2026` 里，绝不插进图像 APC 中间），
  并把 tile 帧切小（governor 已经在控制帧的大小）。
- **UI 帧合并**：鼠标移动报告可能每秒上百次，UI 最多 30 Hz 出去（33 ms 合并窗口），落后时跳过中间状态。
- **所有 UI 写都包 `?2026h … ?2026l`**：现在 wall 的 `writeChrome` 不包（§1）。
  坑：`WallCanvas.render` 在字节发出去**之前**就把 `prev` 换成新格子（`WallCanvas.swift:977`）。
  如果包着文字的块没提交，`prev` 和屏幕就对不上，之后的 diff 永远是错的。文字必须和图在同一个块里一起提交，
  或者提交失败时让 canvas 整屏重画。
- **启动探测一次写完**（§2.2）：`a=q`、`U=1`、16t/14t/18t、OSC 10/11、`?996n`、
  DECRQM 1004/1016/2026/2027/2031/2033/2048、`?u` 一次写出，DA1 收尾。实测 SSH 下 18–34 ms，对比逐个问的 488–534 ms。
  这也是 #99 的解法。接入点在 `main.swift:1031`（wall/mirror 分叉之前、`SCShareableContent` 之前、还没人读 stdin），
  后面的 `PaneGeometry.measure`（`:1451`）、`TermGeometry.query`（`:1245`）和第二次 U=1（`:1468`）改成读缓存。
  **XTVERSION 和 DA2 先不进批次**：XTVERSION 是 DCS 应答，今天的解析器会把它当成 Alt+P 加一串字母**打进远端桌面**
  （`GraphicsReplyTests.testOtherStringSequencesStayKeystrokes`，`Tests/krdcoreTests/GraphicsReplyTests.swift:140` 钉的就是这个），
  而 DA2 对 UI 没用。批次只用 CSI/OSC/APC 应答，按能力探测，不按名字。
- **2048 代替 SIGWINCH + 重新探测**：尺寸变化带像素尺寸一起来，拖动窗口时不用每次再问 16t/14t（#89 记录过
  一次拖动重画 40 次）。今天 `remeasureWallPane` 在 `InputReader` 活着的时候还在自己读 stdin（`main.swift:3312` → `Geometry.swift:242`），
  两个读者抢同一个 fd，换成 2048 也顺带去掉了这个隐患。
- **2033/1004 让画面停下来**：窗口不可见就把 SCStream 帧率降到 0–1 fps，只保留 UI（#110）。

### 5.3 链路状态做成用户看得见的 UI

表头/顶栏的链路胶囊：`● 0.6 ms`（绿）/ `● 24 ms`（黄）/ `● 250 ms+`（红），点开是一张小卡片：

- 往返延迟 p50/p99（`RTTProbe`）、带宽（`MB/s`）、governor 当前档位和原因（「管道落后：画质 80→70」）；
- 如果往返呈现 `ObscureKeystrokeTiming` 的特征，提示：
  「SSH 正在混淆按键时序，每次点击都会多等一二十毫秒。在 `~/.ssh/config` 里给这台主机加
  `ObscureKeystrokeTiming no` 可以去掉」，附可复制的配置片段（OSC 52 一键复制）。
  - 判据：**样本 ≥ 8，最小往返 < 2 ms，中位数 ≥ 4 ms**。实测：默认 0.71/23.5，`interval:5` 0.70/5.79，
    `interval:80` 27.7/65.9（最小值也被抬高，判据会漏掉，可以接受，提示是锦上添花），关掉后 0.39/0.60。
  - 停手 1–3 s 后的第一个字节不排队（`clientloop.c:655`），所以最小值能反映真实链路。
- **wall 里今天没有 RTT 探针**：`ESC[5n` 只在 `probeRoundTrip()`（`main.swift:3476`）里发，它只被
  `startDiagnostics()` 调用，而 `startDiagnostics()` 只在 mock（`:1144`）和 mirror（`:1340`）里跑。
  回包通道在 wall 里是通的（#162 之后 `CSI 0n` → `.statusReport`），所以胶囊要先在 wall 里补一个 1 Hz 的探测 tick。

## 6. 分阶段落地

每个阶段都能单独合并、单独验证，都不影响画面路径。

| 阶段 | 内容 | 验证 |
|---|---|---|
| **P0 地基** | ① 启动探测一次写完 + 能力表（`TermCaps`），② 开 2027 + 宽度改用 libghostty 生成的表（修 `☰`/国旗），③ wall 的文字和图放进同一个 2026 块，④ RTT 降档误判修复（§7.1，#93 同源），⑤ 链路胶囊 + ObscureKeystrokeTiming 提示 | `probe/termcaps.py` 对比；启动时间（#99）；宽度单测用 §2.3 的表；红绿测试 |
| **P1 组件和命中** | 控件树、hover/pressed/focus 状态机、按需开 1003、OSC 22 指针形状、键盘焦点 | 无头 libghostty 测试：屏幕断言 + 指针形状 + 每个动作的字节预算 |
| **P2 主题** | OSC 10/11 派生配色、2031 跟随（先修 `?997;Nn` 被当 DSR）、品牌强调色、圆角卡片 | Rex 截取 VT + HTML 导出对比；深色/浅色两套截图 |
| **P3 mirror 顶栏 + 快速设置**（#87） | 延迟显示、`☰` 浮层、三根滑块 + 自动/固定语义 | 拖动时 governor 不回弹；浮层开关不触发 tile 重发；关闭后图回来（§2.5 的方法） |
| **P4 图标层** | kitty 图标缓存、`a=f` 加载动画（替换 188 KiB/s 的 `▀` 动画） | 加载期间字节 < 4 KB/s |
| **P5 引入 libghostty** | xcframework release asset、`binaryTarget`、无头渲染测试进 CI | CI 绿；krd 体积增量 < 150 KB（实测宽度函数 +86 KB） |

P0–P3 都**不需要先引入 libghostty**：宽度表可以离线用 libghostty 生成后提交（像 kitty 的
`rowcolumn-diacritics.txt` 那样），无头测试可以先放在 `probe/`。这样 P5 失败也不影响产品。

**P0 的文件归属**（避免并行的分支互相冲突）：

| 子任务 | 主要文件 | 和谁冲突 |
|---|---|---|
| ① 批量探测 + `TermCaps` | `Sources/krd/Geometry.swift`、新文件 `Sources/krdcore/TermCaps.swift`、`main.swift:1031/1245/1451/1468` | 开着的 #179/#180/#181 都改 `main.swift`，但不在这几行 |
| ② 2027 + 宽度表 | `Sources/krdcore/Render.swift:171/178/254/263`、`Sources/krd/TextWidth.swift`、生成的表、`docs/PROTOCOL*.md` §1/§4 | 依赖 ① 的「2027 初始值」 |
| ③ wall 文字进 2026 | `Sources/krdcore/Render.swift`（`writeChrome`/`beginFrame`）、`main.swift:1905-1961` | 和 ② 同改 `Render.swift`，不同函数 |
| ④ RTT 误判 | `Sources/krdcore/RTTProbe.swift`、`main.swift:2834` | 无 |
| ⑤ 胶囊 + 提示 | `Sources/krd/WallCanvas.swift` 表头、新的 wall 探测 tick | 依赖 ④ |

## 7. 风险和回退

- **不同终端行为不同**：Ghostty/Rex 都基于 libghostty，但 kitty/WezTerm 不是，而且 Rex 和 Ghostty 连 2027 的默认值都相反。
  所有新能力都由 `TermCaps` 决定；探测不到 2027 就用不开 2027 的宽度，探测不到 1016 就用格子坐标，探测不到 2031 就不跟随。
  今天的界面就是「什么都没探测到」时的回退。
- **2027 的复位不能一刀切**：Ghostty 默认开着 2027。krd 退出时如果无条件发 `?2027l`，会把用户 shell 的宽度模式改掉
  （Ghostty 里 emoji 从此变窄），违反 #134「会话只复位自己打开的东西」。实测 `XTSAVE/XTRESTORE`（`CSI ?2027 s/r`）在两个终端上都能正确往返
  （Ghostty：1 → 关 → 恢复 1；Rex：2 → 开 → 恢复 2），但从没保存过就 `r` 会把 Ghostty 的 2027 关掉（1 → 2）。
  所以规则是：**启动探测读到初始值；初始值是 2 才发 `?2027h`，退出时才发 `?2027l`；初始值是 1 什么都不发。**
  heal（上一个被杀掉的会话留下的残局）不碰 2027：残局里 2027 开着最多是宽度变「对」，不会错位。
- **占位符格子被文字覆盖**：§2.5 已在 Ghostty 1.4.0 实测通过；Rex 只能读文字层，像素待验证；kitty 待验证。
- **Zig/libghostty 构建链**：只在 CI 里用，失败时提交的宽度表照样能用。
- **`☰` 这类宽字符在不同终端宽度不一样**：用 §2.3 的方法在启动时对少数关键图标测一次宽度
  （打印 + CPR，一次写完），以测量结果为准。

### 7.1 已核实：一次 RTT 离群就会降一档

链路是这样的（scout 逐行核对过，算术是按代码模拟的）：

1. `rttLate = rttProbe.lastMs > rttBudgetMs`（`main.swift:2834`）只看**最近一次**回包，没有任何平滑；预算默认 250 ms。
2. `lastMs` 就是 `series.last`（`RTTProbe.swift:43`）。探测每 2 s 一次，回包只在 1 Hz 的 tick 上被消费，
   所以一个样本会当 2.0 s 的「最近一次」。这 2 s 里**每一帧**都算迟到。
3. 两个 governor 的降档条件：3 s 窗口里迟到比例 **> 0.5**，至少 3 个样本，窗口跨度 ≥ 2.7 s
   （`QualityGovernor.swift:58-60`、`:100-101`、`:143`）。

| 场景（一次 258 ms，其余 25 ms） | 窗口里迟到帧 | 比例 | 结果 |
|---|---:|---:|---|
| 20 fps，画质阶梯（默认配置） | 31 / 61 | 0.508 | **降一档**，约 12 s 后才升回 |
| 2 fps，画质阶梯 | 4 / 7 | 0.571 | **降一档** |
| 20 fps，scale（`--quality` 固定时） | 31 / 61 | 0.508 | **降一档** |
| 2 fps，scale | 4 / 7 | 0.571 | **降一档** |

- 更糟的情况：终端停止回 DSR 以后，`expire()` 不清 `series`，`noteFrame` 也不看 `isMeasuring`。
  如果最后一次回包恰好超预算，`lastMs` 就**永远**停在那个值，每帧都算迟到，阶梯一路降到底且升不回来，
  而面板此时显示 `rtt: —`。
- 现有测试没覆盖这条链：`grep -rn rttLate Tests` 为空；`ScaleGovernorTests.testOneSlowFrameIsNotBackpressure`（`:37`）
  只喂了**一个**迟到样本，测的不是「一个样本被持有 2 s」这种真实形态。
- #93 说的是反方向（卡顿被稀释成一个迟到样本），同一个 `noteFrame` 形状的两面，修复一起做：
  迟到判定改用「最近 N 个样本的中位数」或「本帧期间是否有未回的探测超过预算」，`unavailable` 时不参与判定。
  这是 P0 ④，先写红测试。

## 8. 不做

- 本地 GUI 客户端或浏览器前端：另一个产品。
- 在 krd 里嵌一个完整终端（把远端 shell 显示在 krd 里）：libghostty 能做，但不是这次的目标。
- OSC 66 文字缩放：Rex 和 Ghostty 都不支持（§2.1）。
- 依赖 Nerd Font 才好看的设计：只作为探测到之后的增强。
- 用 XTVERSION/DA2 按终端名字分支：按能力探测（§5.2）。

## 9. 复现

```bash
# 能力 + 延迟（本机 Rex，以及经 SSH）
python3 probe/termcaps.py --json /tmp/caps-local.json
scp probe/termcaps.py krd-vm:/tmp/ && ssh -t krd-vm python3 /tmp/termcaps.py --json /tmp/caps-ssh.json
ssh -o ObscureKeystrokeTiming=no -t krd-vm python3 /tmp/termcaps.py --json /tmp/caps-nookt.json
for n in 5 20 80; do ssh -o ObscureKeystrokeTiming=interval:$n -t krd-vm python3 /tmp/termcaps.py --json /tmp/caps-i$n.json; done
python3 probe/termcaps.py --report /tmp/caps-ssh.json

# 浮层盖在 U=1 画面上 + 写回占位符 + OSC 22（在要测的终端里跑，然后截图）
python3 probe/placeholder_overlay.py 20 30 8    # 持续 20 s；30 s 才发 OSC 22（即不发）；8 s 时把 A 区写回占位符
python3 probe/placeholder_overlay.py 30 12      # 12 s 时发 OSC 22 pointer，鼠标停在图上看指针

# VM 里的 Ghostty（不需要登录桌面，但 VM 要醒着）
ssh krd-vm 'caffeinate -u -t 40 >/dev/null 2>&1 & open -na ~/Applications/Ghostty.app --args -e python3 /tmp/placeholder_overlay.py 20 30 8'
ssh krd-vm 'sleep 5; screencapture -x /tmp/covered.png; sleep 6; screencapture -x /tmp/restored.png'

# krd 输出的原始字节（wall 首屏）
ssh -t krd-vm 'script -q /tmp/wall.ts ~/bin/krd --wall'     # Ctrl-\ 退出，然后 scp 回来分析

# libghostty v1.4.0 + Swift
curl -fsSLO https://ziglang.org/download/0.17.0/zig-aarch64-macos-0.17.0.tar.xz   # sha256 b607e9b9…c536a
git clone --depth 1 --branch v1.4.0 https://github.com/ghostty-org/ghostty
cd ghostty && zig build -Demit-lib-vt -Doptimize=ReleaseFast    # 143 s，产出 zig-out/lib/ghostty-vt.xcframework
# 再照 example/swift-vt-xcframework 写 binaryTarget（本地 path 必须是相对路径）
```

## 10. 交给实现方定的三件事

用户说「全权交给你」（2026-10-31）。三条都按原建议定，理由如下：

1. **libghostty 的角色 = 参考终端**（§3.1），不当渲染器。理由：krd 的输出本来就是 VT 字节，远端没有屏幕可画；
   宽度、无头测试、字节预算三件事都只需要「一个和用户终端同源的解析器」。
2. **滑块语义 = 拖就是固定，点「↺ 自动」恢复**（§4.2）。理由：和 `--quality 80` 的现有语义一致，#87 抱怨的
   「拖完自己跑回去」直接消失，状态在 UI 上一眼可见。
3. **交付 = CI 编 xcframework + `binaryTarget(url:checksum:)`，另提交一份生成的宽度表**（§3.2）。理由：用户不需要 Zig；
   CI 挂了、二进制拿不到时，提交的表照样让 `swift build`/`swift test` 通过。
