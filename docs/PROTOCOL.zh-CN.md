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
ESC [ ? 1003 l  ESC [ ? 1002 l  ESC [ ? 1006 l    #   先关掉鼠标上报（万一之前没关）
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

最前面几条就是*自愈*序列：一个卡在等 `ST` 的 pane 什么都不会显示（连文字都不显示），而 `kill -9`
正好落在 `write()` 中间就是这种状态。再跑一次 krd 会自动修好；手工修是
`printf '\033\\\033[?2026l\033[?25h'`。

## 2. 一块瓦片

每块瓦片自带一个同步更新块、并且单独 flush（`ScreenWriter.emitTile`），所以终端不可能显示半块瓦片：

```
ESC [ ? 2026 h                                        # 同步块开始
ESC [ <row> ; <col> H                                 # CUP 到瓦片左上角
ESC _ G f=32,s=<w>,v=<h>,a=t,o=z,q=<Q>,i=<iid>,m=1;<base64 分块> ESC \
ESC _ G m=1;<base64 分块> ESC \                       # …… 重复，每块 4096 字符
ESC _ G m=0;<base64 分块> ESC \                       # 最后一块
ESC _ G i=<iid>,p=<pid>,a=p,q=<Q>,C=1,c=<cols>,r=<rows> ESC \
ESC [ ? 2026 l                                        # 提交
```

逐字段：

| 字段 | krd 给的值 | 为什么 |
|---|---|---|
| `f=32` | RGBA，每通道 8 位 | `Capture` 已经产出 RGBA；不需要调色板，也不需要 PNG |
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
ESC_Gf=32,s=272,v=264,a=t,o=z,q=2,i=100,m=1,<4096 个 base64 字符>ESC\
ESC_Gm=0,<剩下那些 base64 字符>ESC\
ESC_Gi=100,p=1000,a=p,q=2,C=1,c=16,r=8ESC\
ESC[?2026l
```

`KRD_NOSYNC=1` 会去掉两个 `?2026` 转义（给那些同步更新和图像放置配合不好的终端）。

## 3. 整帧路径（`--full-frame`）

整帧一个同步块，一个 image id（`2`）、一个 placement id（`2`）：

```
ESC [ ? 2026 h
ESC [ 1 ; 1 H
ESC _ G f=32,s=<W>,v=<H>,a=t,o=z,q=<Q>,i=2,m=1;<分块> ESC \
ESC _ G m=…;<分块> ESC \        （重复）
ESC _ G i=2,p=2,a=p,q=<Q>,C=1,c=<cols>,r=<rows> ESC \
ESC [ ? 2026 l
```

id 复用规则和瓦片一样：覆盖上一帧，永不删除。这条路径存在的意义是拿来做瓦片的 A/B 对照，以及在
瓦片出问题时当退路。

## 4. 稳态、清理、收尾

```
采到一帧但没有脏瓦片：                    ESC [ ? 25 l
resize 或显式清理（ScreenWriter.clear）：  ESC _ G a=d,d=a ESC \   然后   ESC [ 2 J
会话结束（ScreenWriter.endSession）：
    ESC \                                    # 先把可能写了一半的 APC 收尾
    ESC [ ? 2026 l
    ESC _ G a=d,d=a ESC \  ESC [ 2 J         # 删掉所有 placement，清屏
    ESC [ ? 1003 l  ESC [ ? 1002 l  ESC [ ? 1006 l
    ESC [ ? 25 h
    ESC [ ? 1049 l                           # 离开备用屏
```

`a=d,d=a`（删除所有 placement）**只**在这两个位置发，帧与帧之间绝不发。

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
| `ESC [ 1;…` | 修饰位：`n-1` 的 & 1 shift、& 2 alt、& 4 ctrl、& 8 cmd |
| `ESC [ <code> ~` | 1,2,7 → Home；3 → forward delete；4,8 → End；5/6 → page up/down；11–14 → F1–F4；15 → F5；17–21 → F6–F10；23,24 → F11,F12（**目前会越过 F 键表末尾直接崩 —— 见 [TROUBLESHOOTING](TROUBLESHOOTING.zh-CN.md#22-按-f11-或-f12-会让进程直接退出)**） |
| `ESC O A–D / H / F / P–S` | SS3 方向键、Home/End、F1–F4 |
| `0x00` | Ctrl-Space |
| `0x01`–`0x1A` | Ctrl-A … Ctrl-Z（带 `maskControl`） |
| `0x1C` | **退出**（不转发） |
| `0x7F`、`0x08` | Backspace |
| `0x09`、`0x0A`、`0x0D` | Tab、Return |
| 单个 `ESC` | Esc —— 读循环等满 100 ms（`poll` 超时）且缓冲里只有一个字节时才判定 |
| `ESC` + 字符 | Alt-`字符` |
| 可打印 ASCII | 查 `Keys.map` 的 US/ANSI 虚拟键码；需要 Shift 的符号（`!@#$…`）按基础键并补 `maskShift`；大写字母同理 |
| 其它 | 用 `virtualKey 0` + `keyboardSetUnicodeString` 发一个 `CGEvent` |

**没有 kitty 键盘协议**握手（`CSI > 9 u`），所以裸修饰键、按键释放、Cmd 组合永远收不到。Alt+键 是能
收到的，形式是 `ESC`+键。

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
