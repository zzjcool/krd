# 协议

[English](PROTOCOL.md) | 简体中文

krd 对终端说的每一句话，以及它期望收回来的每一句话。这里是
[kitty 图形协议](https://sw.kovidgoyal.net/kitty/graphics-protocol/)的一个*子集*，加上输入需要的
DEC/xterm 模式；没有任何 krd 自创的东西。下文字节除标注 `…` / `<>` 外都是字面量。

记号：`ESC` = `0x1B`，`CSI` = `ESC [`，`APC` = `ESC _`，`ST` = `ESC \`。一条 kitty 图形命令是
`APC G <key=value,…> ; <payload> ST`；payload 是 base64，可以拆到多条 APC 里。

## 1. 会话框架

```
                                     # 会话开始（ScreenWriter.beginSession）
ESC \                                #   ST：补上被前一个进程留下的 APC
ESC [ ? 2026 l                       #   补上没结束的同步更新块
ESC [ ? 1016 l  ESC [ ? 1006 l  ESC [ ? 1002 l  ESC [ ? 1003 l    #   先关掉鼠标上报（万一之前没关）
ESC [ 0 m                            #   SGR 复位
ESC [ ? 25 h                         #   初始化阶段先让光标可见
ESC [ ? 1049 h                       #   备用屏（不污染 scrollback，滚轮事件交给我们）
ESC [ 2 J  ESC [ H                   #   清屏 + 归位
ESC [ ? 25 l                         #   整场会话隐藏光标

                                     # 确认 stdin 是 tty 之后（InputReader.start）
ESC [ ? 1003 h                       #   any-motion 跟踪：不按键也报移动
ESC [ ? 1002 h                       #   按钮事件：按下 / 拖动 / 释放
ESC [ ? 1006 h                       #   SGR 编码（坐标不设上限）
ESC [ ? 1016 h                       #   SGR *像素*：坐标单位是设备像素，不是单元格
```

最前面几条是*自愈*：卡在等 `ST` 的 pane 什么都不会显示（连文字都不显示），而 `kill -9` 正好落在
`write()` 中间就是这种状态；`?2026l` 补上被杀进程可能留下的同步更新块。四条鼠标复位
（`?1016l ?1006l ?1002l ?1003l`）就是 `ScreenWriter.mouseReset` —— §7 启用列表反过来 —— 跟输入停下时
`writeMouseReporting(false)` 发的、以及收尾时（§4）发的是同一份列表，所以任何一个模式都不可能只被打开、
却没有被这三处一起关掉。再跑一次 krd 会自动修好；手工修是 `printf '\033\\\033[?2026l\033[?25h'`。

这一节里没有任何一条是 kitty 图形 APC —— 开头那个 `ESC \` 是裸的 `ST`，不是信封 —— 所以 tmux
passthrough（§6.6）不改动 §1 的任何一个字节。

## 2. 一块瓦片

整帧只开一个同步更新块，所有脏瓦片在同一块里传完再一起提交（`ScreenWriter.beginFrame` /
`endFrame`）：每帧 16 字节开销而不是每瓦片 16 字节，终端也只提交一次。`KRD_SYNC=tile` 可退回
每瓦片一块，`KRD_NOSYNC=1` 完全关掉：

```
ESC [ ? 2026 h                                        # 同步块开始
ESC [ <row> ; <col> H                                 # CUP 到瓦片左上角
ESC _ G f=24,s=<w>,v=<h>,a=t,o=z,q=<Q>,i=<iid>,m=1;<base64 分块> ESC \
ESC _ G m=1;<base64 分块> ESC \                       # …… 重复，每块 4096 字符
ESC _ G m=0;<base64 分块> ESC \                       # 最后一块
ESC _ G i=<iid>,p=<pid>,a=p,q=<Q>,C=1,c=<cols>,r=<rows> ESC \
ESC [ ? 2026 l                                        # 提交
```

逐字段：

| 字段 | krd 给的值 | 为什么 |
|---|---|---|
| `f=24` / `f=32` | RGB / RGBA，每通道 8 位 | 桌面不透明，默认 `f=24`（少 25 % 字节，`--format rgba` 可退回）；不需要调色板，也不需要 PNG |
| `s=<w>`、`v=<h>` | 瓦片的像素尺寸 | 是这块瓦片自己的矩形，不是整帧 |
| `a=t` | 只传输 | 放置是另一条命令，见下 |
| `o=z` | zlib 压缩负载 | RFC **1950** 流（见 §6.1） |
| `q=<Q>` | 正常是 `2` | `0` = 要回复，`1` = 只回错误，`2` = 静默 |
| `i=<iid>` | `100 + 瓦片序号` | 整场会话固定 |
| `m=1` / `m=0` | 还有分块 / 最后一块 | 续传的 APC 只带 `m=…;` |
| `p=<pid>` | `1000 + 瓦片序号` | placement id，同样固定 |
| `a=p` | 放置 | `C=1`、`c`、`r` 描述占位 |
| `C=1` | 不移动光标 | 见 §6.2 |
| `c=<cols>`、`r=<rows>` | 占位多少格 | 永远是整数格；边缘瓦片更小 |

137×44 格布局里的第一块瓦片（9×6 里的第 0 块，272×264 px，16×8 格）长这样：

```
ESC[?2026h
ESC[1;1H
ESC_Gf=24,s=272,v=264,a=t,o=z,q=2,i=100,m=1,<4096 个 base64 字符>ESC\
ESC_Gm=0,<剩下那些 base64 字符>ESC\
ESC_Gi=100,p=1000,a=p,q=2,C=1,c=16,r=8ESC\
ESC[?2026l
```

`KRD_NOSYNC=1` 会去掉两个 `?2026` 转义（给那些同步更新和图像放置配合不好的终端）。

打开 `--passthrough on`（`KRD_PASSTHROUGH`）时，这一节里每一条 APC —— 每个 `m=1`/`m=0` 传输分块，
以及每条 `a=p` 放置（包括 `U=1` 的虚拟放置）—— 都套进 tmux 的 DCS 信封（§6.6）：命令本身不变，
前面加 `ESC P tmux;`，内部每个 `ESC` 翻倍，末尾补 `ESC \`。两个 `?2026` 转义不套。

## 3. 整帧路径（`--full-frame`）

整帧一个同步块，一个 image id（`2`）、一个 placement id（`2`）：

```
ESC [ ? 2026 h
ESC [ 1 ; 1 H
ESC _ G f=24,s=<W>,v=<H>,a=t,o=z,q=<Q>,i=2,m=1;<分块> ESC \
ESC _ G m=…;<分块> ESC \        （重复）
ESC _ G i=2,p=2,a=p,q=<Q>,C=1,c=<cols>,r=<rows> ESC \
ESC [ ? 2026 l
```

id 复用规则和瓦片一样：覆盖上一帧，永不删除。这条路径存在的意义是拿来做瓦片的 A/B 对照，以及在
瓦片出问题时当退路。开关打开时它那几条 APC 和 §2 一样套信封（§6.6），`?2026` 那一对不套。

## 4. 稳态、清理、收尾

```
采到一帧但没有脏瓦片：                    ESC [ ? 25 l
resize 或显式清理（ScreenWriter.clear）：  ESC _ G a=d,d=a ESC \   然后   ESC [ 2 J
会话结束（ScreenWriter.endSession）：
    ESC \                                    # 先把可能写了一半的 APC 收尾
    ESC [ ? 2026 l
    ESC _ G a=d,d=a ESC \  ESC [ 2 J         # 删掉所有 placement，清屏
    ESC [ ? 1016 l  ESC [ ? 1006 l  ESC [ ? 1002 l  ESC [ ? 1003 l
    ESC [ ? 25 h
    ESC [ ? 1049 l                           # 离开备用屏
```

四条鼠标复位就是 `ScreenWriter.mouseReset` —— §7 启用列表反过来 —— 与进来自愈时（§1）、以及输入停下时
`writeMouseReporting(false)` 发的是同一份列表：一个模式再也不可能被打开、却没有被这三处一起关掉。

`a=d,d=a`（删除所有 placement）**只**在这两个位置发，帧与帧之间绝不发。打开 passthrough 时它和
别的 APC 一样套信封（§6.6）；`?2026l`、`2J`、四条鼠标复位不套。

## 5. krd 刻意不发的那些

| 不发 | 原因 |
|---|---|
| 逐块瓦片的 `a=d` | 各终端对它的作用域理解不一致；把 id 级删除当「清空全部」的终端会直接黑屏（§6.3） |
| 每块瓦片轮换两个 image id | 那会让两张图占同一块格子，旧的那张会透出来 |
| `z=`（层叠）、`x`/`y`/`X`/`Y`（偏移）、`t=f`/`t=t`/`t=s`（文件介质） | 整格 `c`/`r` 放置一个都不需要，而且文件介质在 SSH 场景根本用不了 |
| `f=100`（PNG）、`f=24`（RGB） | RGBA + zlib 比 PNG 更省 CPU，PNG 还要多一个编码器 |
| `a=T`（传输并显示） | 它把放置烤进传输命令里；逐瓦片 `a=t` + `a=p` 才是固定 id 方案成立的前提 |
| unicode 占位符、`a=f` 动画帧、`a=q` 能力查询 | 渲染器用不到；`a=q`/`a=f` 只在可行性调研阶段探过 |

## 6. 为什么这么选

### 6.1 `o=z` 要的是 RFC 1950 zlib，不是裸 DEFLATE

Apple 的 `COMPRESSION_ZLIB` 输出的是*裸* DEFLATE 流 —— 没有 2 字节 zlib 头，也没有 Adler-32 尾。
按 RFC 1950 解压的终端会回 `EINVAL: decompression failed`（只有 `KRD_Q=0` 才看得见），然后什么
都不画：一块黑屏，没有任何其它症状。所以 krd 直接调系统 `libz`：
`compress2(dst, &len, src, srclen, 5)`（`CZlib` 模块，固定 level 5）。

### 6.2 每个 placement 都要 `C=1`

不给它，贴图就会移动光标 —— 有的终端会推到图后面，也就是推到或推过 pane 的最后一行。结果要么是
下一次 `CUP` 和一个已经动了的光标打架，要么是在最后一行写入触发整屏滚动；而每块瓦片都是按绝对坐标
贴的，一滚整幅画面就错位。`C=1`（「不要移动光标」）把这一整类 bug 消掉了。

### 6.3 固定 id，不删除

`iid = 100 + 瓦片序号`，`pid = 1000 + 瓦片序号`，整场会话固定。每一帧都传到同一张 image 里，并在同样的
格子上重新放置，于是上一帧的 placement 被就地覆盖。带来三件事：

- 没有任何东西需要删除，所以也没有哪个终端的删除语义能伤到我们。Herdr 和 rex 都把
  `a=d,i=<id>` 当作「丢掉整批图像」；而「先删后放」的方案在老实实现的终端上还会闪一帧黑。
- placement 总数被瓦片网格封顶（实测布局是 54 个），不会累积 —— `ScreenWriter.reapInterval`
  （定期全删再重绘）被编成 `0`，那条路今天是死代码。
- 万一某个终端忽略 placement 覆盖，症状是一块瓦片发旧，而不是黑屏，好排查得多。

### 6.4 每块瓦片一个 `?2026` 块

DEC 同步更新（`?2026h … ?2026l`）告诉终端「先别重绘，等我说完」。把每块瓦片（而不是整帧）包起来，
是在缩小原子单元：终端看到的要么是旧 placement、要么是新 placement，绝不会是半张图；而且一次被打断
的写入不会把多块瓦片的一帧冻在半应用状态。代价是每块瓦片多两个转义。

### 6.5 `?25l` 这个保活字节

有的终端要等到下一次输出周期才提交 placement。krd 在一帧采到了、但**没有**任何脏瓦片时补一个
`ESC[?25l`，让管道继续走（顺便确认光标保持隐藏）。完全静止的桌面一个字节都不发：和上一帧逐字节相同
的帧在进入渲染器之前就被采集侧丢掉了。

### 6.6 tmux passthrough（#107）

tmux 的 pane 是夹在 krd 和你真正在看的终端之间的一层终端模拟器：转义流是它自己解析的，默认情况下
APC 到它这里就断了 —— 图像永远到不了外层终端。占位*格子*是普通文字，所以它们能穿过去，外层终端
把 `U+10EEEE`（它没有这个字形）画成一格格方框。tmux 愿意转发的是它的 DCS passthrough，默认不开，
要程序自己选：`--passthrough auto|on|off`，或 `KRD_PASSTHROUGH`，默认 `auto` = `TERM` 以
`tmux`/`screen` 开头时套，其它终端不套（flag 优先于变量）。

打开之后，krd 发出的每一条 kitty APC —— 每个 `a=t` 传输分块、每条 `a=p` 放置（包括 `U=1` 的虚拟
放置）、那条 `a=d,d=a` 删除，以及 §6.7 几何探测自己的 `a=t`/`a=p`/`a=d` 和 `KRD_DELTEST` 那条
孤零零的 `a=d` —— 都变成

```
ESC P tmux;  ESC ESC _ G <那条 APC 自己的字节> ESC ESC \  ESC \
```

也就是 §2/§4 画的那条 APC 原样，内部每个 `ESC` 翻倍（`ESC _` → `ESC ESC _`，APC 自己的结束符
`ESC \` → `ESC ESC \`），前面 `ESC P tmux;`，后面 `ESC \`（`ESC P tmux;` 是 7 字节，也就是
`\ePtmux;` —— 中间的空格是本文的记号习惯，和 §1 写 `ESC [ ? 2026 l` 一样）。翻倍是机制而不是
引号习惯：tmux 用遇到的**第一个** `ESC \` 结束信封，内部的 `ESC \` 会把信封断在画面中间 ——
翻倍之后它对这次扫描不可见，tmux 转发出去时再拆回一层，于是外层终端收到的就是 krd 写的那条
APC，一个字节不差。

**「每一条」是结构上成立的，不是逐个调用点的承诺。** 图形转义只可能由 `GraphicsAPC`
（`krdcore/GraphicsAPC.swift`）构造，而它查的那个开关在任何字节发出之前就按进程设好了一次 ——
所以几何探测（§6.7，它在 `ScreenWriter` 存在之前就写到裸 fd 1 上）和传输分块走的是同一个决定。
两道保险：`GraphicsAPC.writeRaw`（探测的写）和 `ScreenWriter.flushLocked`（帧的出口）在真正
发出之前都会跑一遍信封解析器 `GraphicsAPC.isFullyEnveloped` 并 assert；将来谁再手搓一条
`ESC _ G…`，debug 跑一次就炸，`TmuxPassthroughTests.testEveryAPCInACapturedStreamIsEnveloped`
也会红，而不是在 pane 里悄悄失效。

代价：每条 APC 多 11 字节 —— 引导符从 2 字节变成 3 字节（翻倍的 `ESC _`），APC 自己的 `ST`
从 2 变 3（翻倍的 `ESC \`），前面 `ESC P tmux;` 再加 7 字节、后面信封自己的 `ESC \` 加 2 字节。
画面本身没有别的变化：`U=1` 占位符和信封是*叠加*关系，不是替代关系 —— 占位格依旧是
普通文字（这正是 tmux 支持的传输方式），只有图像数据走 DCS 里面。

刻意**不**套的：

| 不套 | 原因 |
|---|---|
| `?2026h` / `?2026l` | tmux ≥ 3.7 自己就实现了同步输出，更早的版本根本没有：套进去等于把这个模式从「画这块 pane 的那个进程」手边送到它后面去，而不是让它生效 |
| 鼠标模式（`?1002`/`?1003`/`?1006`/`?1016` 和那四条复位） | 上报鼠标的是 tmux 自己，这些必须送到**它**手里；送过去之后就没有任何东西能打开或关掉跟踪了 |
| OSC 52（§7.4） | 剪贴板属于 krd 直接连着的那个终端 —— tmux 有自己的缓冲，靠 `set-clipboard` 转发，而往外层发的 `out` 读请求永远不可能再从 stdin 回来 |
| kitty 键盘协议（`CSI > 15 u`、`CSI ? u`、`CSI < u`） | krd 要按它的**回**决定行为，而能回这个的只有 tmux —— 它实际对话的那个终端 |
| 占位格本身 | 它们是文字（`U+10EEEE` 加变音符号），不是转义：tmux 像其它格一样重写它们，需要信封的是它们指向的那张图 |

已测的是变换本身，不是真实 pane：`--selftest --no-input` 61112 B，`--passthrough on` 68119 B、
637 个信封，拆回去与明文逐字节相同（把明文里每段 `ESC _ … ESC \` 正向套一遍，也能逐字节还原
出包装流）—— 但**本机没有装 tmux**，所以端到端的 pane 测试没有跑。`auto` 的判断、翻倍规则和
11 字节的代价来自 tmux 自己的解析器和文档，不是来自一个活的 pane。

限制：需要 tmux ≥ 3.3 且 `allow-passthrough` 打开（`set -g allow-passthrough on`，默认关），而且
只能嵌一层（DCS 里再套 DCS 不转发）。tmux < 3.7 根本没有 `?2026`，所以那种环境下画面是分段到的：
不会冻住，但 resize 时可能撕裂。

## 7. 输入：终端发来的那些

只有在 stdin 是 tty（`isatty(STDIN_FILENO) == 1`）时才打开鼠标上报；否则 krd 记一条
`krd: input DISABLED …` 并且不打开鼠标模式 —— 不然终端会把自己的上报当文字糊在画面上。

| 模式 | 含义 | krd 拿它做什么 |
|---|---|---|
| `?1003h` | any-motion 跟踪 | 不按键的指针移动 → `mouseMoved`（hover、指针跟随） |
| `?1002h` | 按钮事件跟踪 | 按下、释放，**以及按住时的移动**（拖动） |
| `?1006h` | SGR 编码 | 用 `<Cb;Cx;CyM` / `…m`，而不是 8 位的老编码 |
| `?1016h` | SGR-Pixels（kitty 扩展） | 坐标单位是设备像素，不是单元格 |

上报形如 `ESC [ < Cb;Cx;Cy M`（按下/移动）和 `ESC [ < Cb;Cx;Cy m`（释放），坐标从 1 开始。`Cb` 的位：

| 位 | 含义 |
|---|---|
| `& 3` | 按钮：0 左 → `leftMouseDown/Up/Dragged`，1 中 → `otherMouse*`，2 右 → `rightMouse*`；**移动**上报里的 `3` 表示「没按键」，会变成 `mouseMoved` |
| `& 32` | 移动（拖动） |
| `& 64` | 滚轮；`& 3` = 0 上、1 下、2 左、3 右；垂直方向发 ±1 行，水平方向发到 `wheel2` |
| `& 4`、`& 8`、`& 16` | 按住 shift / alt / ctrl → 注入事件带 `maskShift` / `maskAlternate` / `maskControl` |

注入的每个鼠标事件都**显式设置** `flags`（由上面这些位算出，普通点击就是空）。不能让它走默认值：
`CGEvent(mouseEventSource: nil, …)` 会继承**会话的**修饰键状态，而 `postKey()` 给 Ctrl 组合键发的是
`.maskControl`，残留的 Control 会让之后每一次点击都变成 Control+点击 —— macOS 把它当成右键，
而且窗口拖不动。

### 7.1 单元格坐标 vs 像素坐标，以及降级判定

单元格坐标不可能超过终端格数，于是：

```
if Cx > cols || Cy > rows  →  终端在讲像素  →  粘住 pixelMouse = true（不可逆）
```

`cols`/`rows` 来自 `TermGeometry.lastGrid`（最近一次 `read()` 或 `query()` 量到的）。一旦粘住，之后
所有上报都按像素处理，包括来自左上角的小坐标。不认 `?1016h` 的终端永远触发不了这个条件，就一直走
单元格映射 —— 两种终端都能用，谁也不需要握手。

映射回屏幕点（`Viewport`，`sourceRect` = 被采集显示器的 `CGDisplayBounds` 或窗口 frame，单位是全局点）：

```
单元格 (Cx,Cy):  fx = (Cx - 0.5) / cols        fy = (Cy - 0.5) / rows      → 取格中心
像素   (Px,Py):  fx = clamp(Px / pixelW, 0, 1) fy = clamp(Py / pixelH, 0, 1)
       point  =  (sourceRect.minX + fx * sourceRect.width,
                  sourceRect.minY + fy * sourceRect.height)
```

落在 placement 之外的事件直接丢掉（`contains(cell:)` = 1…cols / 1…rows，
`contains(pixel:)` = 0…pixelWidth）。这套算法成立的前提是：画面永远从 pane 的第 (1,1) 格开始贴（备用
屏上整块 pane 都是我们的），像素坐标就是相对这个原点的。

### 7.2 按键

| 输入 | 处理 |
|---|---|
| `ESC [ A/B/C/D` | 上 / 下 / 右 / 左（`Keys.up` … `Keys.left`） |
| `ESC [ H` / `ESC [ F` | Home / End |
| `ESC [ Z` | Shift-Tab |
| `ESC [ 1;…` | 修饰位：`n-1` 的 & 1 shift、& 2 alt、& 4 ctrl、& 8 cmd；开了事件上报后该字段是 `<mods>:<event>` |
| `ESC [ <code> ; <mods> : <event> u` | kitty 键盘协议（§7.3）：带 press/repeat/release 事件的按键上报 |
| `ESC [ ? <flags> u` | 终端对能力查询的回答（§7.3），只读掉、绝不转发 |
| `ESC [ <code> ~` | 1,2,7 → Home；3 → forward delete；4,8 → End；5/6 → page up/down；11–14 → F1–F4；15 → F5；17–21 → F6–F10；23,24 → F11,F12；25,26 → F13,F14。一张表（`Keys.numbered`）：16 和 22 是编号里的空档，直接忽略，表里没有的编号同样忽略 |
| `ESC O A–D / H / F / P–S` | SS3 方向键、Home/End、F1–F4（与 `ESC [ 11 ~` … `ESC [ 14 ~` 同一组键码） |
| `0x00` | Ctrl-Space |
| `0x01`–`0x1A` | Ctrl-A … Ctrl-Z（带 `maskControl`） |
| `0x1C` | **退出**（不转发） |
| `0x7F`、`0x08` | Backspace |
| `0x09`、`0x0A`、`0x0D` | Tab、Return |
| 单个 `ESC` | Esc —— 读循环等满 100 ms（`poll` 超时）且缓冲里只有一个字节时才判定 |
| `ESC` + 字符 | Alt-`字符` |
| 可打印 ASCII | 查 `Keys.map` 的 US/ANSI 虚拟键码；需要 Shift 的符号（`!@#$…`）按基础键并补 `maskShift`；大写字母同理 |
| 其它 | 用 `virtualKey 0` + `keyboardSetUnicodeString` 发一个 `CGEvent` |

**有** kitty 键盘协议握手（§7.3）；但忽略它的终端仍按上面这套 legacy 编码工作、行为不变，这张表
描述的就是那条路径。

### 7.3 键盘协议（kitty）

没有它，`Cmd` 组合、按键释放、连发都收不到：macOS 拿到的只是能打字、不能干活的键盘。握手是两条
写往 **stdout** 的序列，在输入启动时发一次：

```
CSI > 15 u      # push：disambiguate(1) | events(2) | alternates(4) | 所有键都用转义序列(8)
CSI ? u         # query：当前生效的是哪些标志？
```

实现了协议的终端会在 **stdin** 回 `CSI ? <flags> u`；krd 记下它，`--debug` 打印
`input: keyboard protocol flags=<n>`。没有回答就是“只有 legacy”，这是受支持的状态，不是错误。
退出时弹栈（`CSI < u`），把键盘模式还给 krd 后面的 shell。

bit 16（associated text）故意不请求——IME 是 #16，它带的文本字段在此之前只是白负重。

push 被接受后，按键上报长这样：

```
CSI code[:shifted[:base]] ; modifiers[:event] [; text] u
```

- `code` 是**未按 Shift 的** Unicode 码位（`ctrl+shift+a` 是 `97`，绝不是 `65`），或者是功能区
  键在私用区（57344–63743）里的编号。
- `shifted` / `base` 只因为 bit 4 才出现。`base` 是同一个物理键在 PC-101 布局上的键位，正是它让
  西里尔布局下的 `ctrl+С` 去按 `c` 键。
- `modifiers` 与 legacy 字段同一套 `1 + bits`：1 shift、2 alt、4 ctrl、8 super（macOS 上就是**Cmd**）。
  Hyper(16)、meta(32)、锁定位(64/128) 会解进上报里，但**故意**不映射到 `CGEventFlags`。
- `event` 因为 bit 2 才出现：1 press、2 repeat、3 release。

krd 拿到之后怎么做（`Sources/krd/Keyboard.swift`）：

| 上报 | 实际发出 |
|---|---|
| press、repeat | 带该上报 flags 的 down+up —— 和以前每个键一样，连发靠它 |
| release | **只发 up** |
| 码位能在 `Keys.map` 里找到 | 用 US/ANSI 虚拟键码（`Cmd-C` → 键 8 + `.maskCommand`） |
| 码位没有对应 ANSI 键 | 走 `keyboardSetUnicodeString`，和以前一样 |
| 功能键 PUA 码 | `27`/`13`/`9`/`127` → Esc/Enter/Tab/Backspace，`57376`/`57377` → F13/F14；没有映射的 PUA 码直接丢弃，绝不当作字符打进去 |
| 修饰键本身（57441–57454、57358–57360） | 丢弃：其它上报已经带着它们的状态，转发一次 tap 只会叠加 |
| `Ctrl-\`（码位 92，ctrl） | **退出**，且只在 press/repeat；release 不能再结束一次会话 |

协议开着时其余一切仍保持 legacy 形状：方向键还是 `CSI 1;<mods>[ABCD]`，F1–F12 还是
`CSI <n>;<mods>~`，那些序列上唯一新增的是 `:event` 子字段——这也是为什么没有子字段时
`KeyReport.legacyFields` 返回的 `[Int]` 与旧解析一模一样。


### 7.4 剪贴板（OSC 52）

剪贴板是一条*通道*，不是一个键：镜像桌面和本地终端各有一份，彼此看不见，中间必须有序列。krd 双向桥接，
默认关闭（`--clipboard=off|in|out|both`），只走文本，payload 上限 **2 MB**。

**镜像端 → 终端（`in`）。** 以 4 Hz 轮询 `NSPasteboard.general.changeCount`（只比一个整数；krd 没有
`NSApplication` run loop 可以挂观察者）。变了就把文本发出去：

```
ESC ] 52 ; c ; <UTF-8 文本的 base64> ST          # ST = ESC 反斜杠，不是 BEL
```

`c` 是剪贴板选择；`p`（primary）、`s`（select）和 `0`–`7` 的 cut buffer 两个方向都忽略。支持它的终端会
立刻接管这段文本——序列走的是 SSH 会话内部，没有多暴露任何东西。

**终端 → 镜像端（`out`）。** `Ctrl-V`（0x16，kitty 编码下是 `CSI 118;5 u`）发出读取请求：

```
ESC ] 52 ; c ; ? ST
```

支持读取的终端会在 **stdin** 上用同样的 `52;c;<base64>` 形式回答；这时 krd 才把文本放进镜像端的
pasteboard，并通过正常注入路径投一次 `Cmd-V`（所以 `--window` 下它会投给那个窗口所属进程，见 §7.3 的
姊妹规则 #17）。不回答的终端会在 0.8 秒后得到一行提示，并且**什么都不粘**——把镜像端 pasteboard 里
碰巧有的东西粘进去，比什么都不做更糟。`--clipboard-paste <file>` 是不需要终端配合的兜底。

**限制。**

| | |
|---|---|
| payload 上限 | 2 MB；更大的直接丢弃并记 `clipboard: <n> B dropped (limit 2097152 B)` |
| 记什么日志 | 每次同步一行，只有方向和字节数——内容永远不记，`--debug` 也不记 |
| `--no-input` | 强制关掉 `out`：读镜像端剪贴板没问题，往里面按键不行 |
| 分帧 | krd 把整段一次发完：OSC 52 是"替换剪贴板"，分块只会让最后一块生效 |

payload 和帧共用 stdout，所以写入端用同一把锁：OSC 52 落在某张图的两块瓦片中间，会被当成图像数据解码，
把那块瓦片弄坏。


### 7.5 一个字符往哪儿走（`--ime`）

协议送来的是两种不同的东西，它们不能互相替代：

- **按键** —— `CSI 97;5 u` 意思是"物理 `a` 键被按下，带 ctrl"，镜像端的布局和输入法自己决定它是什
  么字符；
- **字符** —— 没有 ANSI 键位对应的码位（CJK 汉字、终端无法映射的带音标字母），只能用
  `keyboardSetUnicodeString` 当文本送进去。

只有第一种能组合。两者都可行时，`--ime` 决定优先哪一个：

| 模式 | 有物理键 | 没有键（已组合的字符） |
|---|---|---|
| `auto` | 按键 | 注入文本，并在日志里说明一次 |
| `raw` | 按键 | **丢弃**：组合过程中塞进半成品字符，比什么都不做更糟 |
| `unicode` | ASCII 按键，其余注入 | 注入文本 |

ASCII 永远按键：把 `a` 当文本注入，只会让所有读 keycode 的应用失明，一点好处都没有。alternate-key
字段（`code:shifted:base`）正是"非 ASCII 字符也有物理键"的来源——有了 `base`，`a` 键上的西里尔字母
`ф` 依然以按键的形式到达目标端，这也是 `--ime=raw` 能成立的全部原因。

## 8. 回复

`q=2` 时所有回复都被吞掉，包括错误 —— 黑屏就没有任何解释。`KRD_Q=0` 打开回复：

```
APC G i=<iid>;OK ST                     # 成功
APC G i=<iid>;<ERRNO>:<text> ST         # 例如 EINVAL: decompression failed、ENOENT: …
```

krd 从不解析回复。它们到达 stdin，而 stdin 处于 raw 模式、正在被当作输入解析，所以一条回复会被理解成
键盘输入（开头是 Alt-`G`），然后被打进被控桌面。**`KRD_Q=0` 一定要配 `--no-input` 用**，或者干脆离线
读 `KRD_DUMP`。

## 9. 参考

- kitty 图形协议：<https://sw.kovidgoyal.net/kitty/graphics-protocol/>
- kitty 键盘协议（本项目未实现）：<https://sw.kovidgoyal.net/kitty/keyboard-protocol/>
- xterm 鼠标跟踪（`1000`/`1002`/`1003`/`1006`）：xterm 源码里的 `ctlseqs`；
  `1016` 是 kitty 给 `1006` 加的像素坐标扩展
- DEC 私有模式 `2026`（同步输出）：<https://gist.github.com/christianparpart/d8a62cc1ab659194337d73e399004036>
