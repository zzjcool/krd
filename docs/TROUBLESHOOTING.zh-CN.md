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

### 1a. 墙的页脚写着 `Terminal cannot draw pictures`

**原因。** 你在 `Terminal.app` 里跑 krd。它不支持 kitty 图形协议，以后也不会，所以 krd 发出去的东西
不可能变成图片——墙只剩文字和空框，任何权限或参数都改不了这件事。krd 认得出这种情况
（`TERM_PROGRAM=Apple_Terminal`），直接在自己的页脚里说出来，否则就是满屏「no picture」加零解释。
**解决。** 换一个支持协议的终端：rex、Ghostty、kitty、WezTerm。从另一台机器跑就用
`ssh -t user@host krd`（`-t` 不能省，否则根本没有 tty）。

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

## 3. 加了「逐块瓦片删除」之后整幅画面被清空

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
→ `--cell <w>x<h>`（什么答案都没有时的兜底是 `8x16`）。终端**只**答 `CSI 14 t`（窗口像素）也够用：单元格按「窗口 ÷ 网格」
推导出来，画面依然和 pane 精确对齐（issue #56 —— 在此之前这种终端会被当成「什么都没答」，80×24 的
pane 出图 640×480）。`--debug` 会写明答的是哪一个问题：
`krd: geometry source CSI 16t+14t`、`CSI 14t (cell derived)`、`--cell` 或 `TIOCGWINSZ`。两个查询都不答时，日志会把后果说清楚（`the image will be WxH for a CxR pane`），
这时再显式传真实单元格尺寸，比如 `--cell 17x33`。

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

**根因（两种，现在都修了）。**
1. resize 路径只用 `TermGeometry.read()` 重新测量、不做 CSI 查询，在不汇报像素尺寸的 pty 上退到 `--cell`，
   而那个值可能已经和新格子不符；
2. 更要紧的一种：**图是终端侧的对象**，挂在它被放置的那些格子上。resize 时如果只重排布局、重画文字，
   终端会把旧图留在原处，新图再叠上去——看起来就是"缩放不支持"或"缩放时有点问题"。
**对策。** wall 的 resize 现在按顺序做四件事：重测格子（`PaneGeometry.measure`，含 `CSI 16t`/`14t`）、
`wallCanvas.invalidate()`、**`a=d,d=a` 删掉所有图**、整帧重画（重新抓图 + 重新放置）。布局不会停在旧值，
旧图也不会残留。pty 里实测 137×44 → 100×30：舞台 86×27 格 / 688×432 px → 54×17 格 / 432×272 px，
删图那一帧夹在两次重画之间。

### 13b. `krd` 打开的是一屏图片，不是桌面

**原因。** 阶段 4 之后这就是 `krd`：落地屏（见 `design-overview.zh-CN.md` §2）上面是舞台里的一块屏、
下面是最近用过的窗口，都是图片，桌面变了才重画。这个模式不转发输入——它是落地屏，不是镜像。
**解决。** 明确要镜像：`krd --mirror`（整块屏，按 `--fps` 刷新），或者 `krd --window <查询>` 只镜像
一个窗口（这个参数隐含镜像，因为"点名要镜像某个窗口"不可能是要墙）。`wall` 和 `--wall` 仍然可用，
仍然指落地屏。

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

### 19. 打中文/日文/韩文没用

**根因。** 两件不同的事，修法相反：

1. 没有物理按键可对应的字符是用 `keyboardSetUnicodeString`（`virtualKey 0`）塞进去的。目标端一个
   keycode 都没收到，它的输入法自然看不到按键：没有组合过程、没有候选窗——而读 **keycode** 的应用
   （Electron 系、Terminal.app、大多数自定义文本视图）干脆什么都收不到。
2. 只有当你用的终端报了物理键（kitty 协议的 alternate-key 字段），而且这个键在你的本地布局上存在，
   字符才会「带着按键」到达。

**对策。** `--ime`：

| 模式 | 行为 |
|---|---|
| `auto`（默认） | 终端报了物理键就按那个键，否则注入字符；退化时会打日志 |
| `raw` | 只按物理键——没有键的文本**直接丢弃**，所以一次组合过程里绝不会被塞进半成品文本（韩文 jamo → 音节） |
| `unicode` | 非纯 ASCII 一律注入：krd 原来的行为，适合你已经在本地组合好字符的场景 |

要**用输入法打字，就把本地的输入法关掉**，让镜像端的输入法去组合：按键会原样到达，候选窗画在镜像
画面里（你本来就在看那块画面），空格/方向键/数字键确认与选择候选。如果日志里出现

    krd: this character has no key on the local layout, so krd injects it as text …

说明是你本地的输入法先组合好了再传给 krd 的——这是 `auto` 的退化路径，`--ime=raw` 会直接丢掉它。
另外，`--ime=raw` 用在没有应答键盘协议握手的终端上时，就只有 ASCII 能打——这是这个模式的取舍，不是 bug。

### 20. 用 `--window` 时，点击打到了最上面的窗口而不是被镜像的那个

**根因（#17 已修）。** `--window` 过去只过滤*采集*：注入仍是全局的 `CGEvent.post(tap: .cghidEventTap)`，
谁在最上面谁来接，所以被遮住一半的窗口每一个点击都会丢。

**对策。** 窗口模式下 krd 改用 `CGEventPostToPid` 把事件投给目标进程——鼠标、滚轮、键盘都一样——所以
不管前面挡着什么，点击都会到被镜像的窗口。坐标仍是屏幕点，取自窗口自己的 frame，目标 app 就是拿它
在自己的窗口里做命中的。

两点值得知道：

- 目标 app 退出或窗口关闭后就没有 pid 可投了。krd 只打一次
  `the mirrored window is gone (no pid) — falling back to global injection`，之后点击重新交给最上面的窗口；
  要重新挂上用 `--window <id>` 重启。
- `--debug` 会记下真正用的 pid（`window mode — events go to pid 1234`，之后每条事件
  `posting to pid 1234 (window mode)`、`pid 1234 <- 1 at 804,298`），所以「这次点击去哪了」是可查的，
  不用猜。

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

### 23f. 没有截图也能复现几何问题

```
krd --wall --demo
```

画的是**测试图**而不是桌面：不需要窗口服务器、不需要屏幕录制授权、不需要 VM，而且每台机器上的数字都一样
（demo 的模型是固定的：一块 2560x1600 显示器和四个窗口，16:9、4:3、1:1、21:9）。图片自己的边框就是尺子，
四个角四种颜色，圆一旦被拉伸就变椭圆，页脚还会打出这一帧是从什么数字画出来的：

```
demo 137x44 · cell 8x16 · 2x · pic 86x27c 1376x864px · a=p · measured from the terminal (CSI 16t+14t)
```

三种情况怎么读：

| 看到什么 | 说明什么 |
|---|---|
| 边框四条边都贴满盒子 | 传输方式是对的；还有问题就是**盒子**的问题，不是图的问题（用 `--wall --pane WxH` 复现） |
| 边框贴满盒子但图发虚 | 终端在放大：调高 `--dpr`（它只管清晰度，不管位置） |
| 边框在盒子里、偏小、贴左上 | 终端按"一图素一设备像素"画，而 krd 要少了：图必须按**设备**像素要。给它真实格子（`--cell 16x33`），或者让 krd 从 pty 读（`ws_xpixel`，本地跑有、ssh 没有） |

`--placeholders` / `--no-placeholders` 切换传输方式，`--dpr N` 改清晰度倍数，四条命令就能让同一个终端和自己对照。

### 23g. 镜像页上等距的黑色横线

**特征**：显示器页里图的位置、大小都对，就是每隔几行有一条细黑线。数一下：118×38 格的页面上是**九条**。
那不是渲染瑕疵、也不是壁纸，而是 tile 行与行之间的缝。

算术是这样的（`--debug` 打第一行，镜像自己打第二行）：

```
krd: mirror grid 118x38 cells at 17x33 px, pane 118x73, src 1920x1200 px, fit 1.045, frame 1920x1200 px
krd: frame 1920x1200 px, grid wants 1920x1200 px (118x38 cells of 17.0x33.0 px, 15x10 tiles)
```

118×38 格、每格 17×33 px，格子一共占 2006×1254 px。如果帧用的是**源自己的**像素（1920×1200），
每个 tile 的像素矩形是 1920×1200 里按比例切出来的，而它的格子是 `8×4` 个 17×33 = 136×132 px。
按"一图素一设备像素"画的终端（Rex）没法把这点差额拉开，于是每行 tile 底部约 12 px 露出背景：
十行 tile，九条缝。

修法：帧**就是**格子那块像素（`TileGrid.make`）。流会上采样到请求的尺寸——实测 1920×1200 → 2006×1254，不丢帧。
截图不行（它会填黑边，见 §23e），所以墙上限是源尺寸、自己再放大一次；两条通道、两条规则。

| 看到什么 | 说明什么 |
|---|---|
| **每行 tile** 一条细缝（10 行 → 9 条），等距 | 帧比格子矮：日志里 `frame` 和 `grid wants` 对不上 |
| 只有图的右边/下边有缝 | 整张图都短了，不是每个 tile：放置比盒子小（§23e） |
| 只有一边一整条黑带 | 宽高比对不上，那是终端自己的格子，不是缝 |
| **两个方向**都有缝（118×38 的页面上下 14 条竖的、9 条横的），画面像被切碎 | 这是"按一图素一设备像素画"的终端上用了 `--scale < 1`：每个 tile 只占自己格子的 `scale`。占位符网格没法拉伸，像素放置可以。现在 `--scale < 1` 会自动切到像素路径（`ScaleTransportTests`）；老版本手动加 `--no-placeholders` |
| 细缝在**每个 tile 列**上（15 列 → 14 条），间距正好一个 tile 宽，只有竖向 | 每个 tile 的图像都比它所在的格子窄。查 `KRD_DUMP` 里的 `s=` 与 `c=`：走占位符这条路时 `s` 必须等于 `c` 乘格子宽——帧小于格子（"按一图素一设备像素画"的终端上用了 `--scale < 1`）或者格子是小数，以前会破坏这一点（issue #86）。重绘一遍还在的缝不是这个：重绘会按同样的矩形把每块 tile 重新放一遍，能被 resize 清掉的只有过期的 placement |


### 23e. 图只占了盒子的一部分 / 贴在左上角

在 kitty 终端上放一张图有两条路，只有一条是对的：**格子**（`U=1` unicode placeholder，默认）和 **像素**
（`--no-placeholders`）。落地屏和镜像都用探测选出来的那一条，所以这一节对两个页面都适用。

1. 用 `--debug` 跑，读 krd 启动时打的两行日志：

   ```
   krd: wall cell 8x16 px, measured from the terminal (CSI 16t+14t) (not device pixels) - 137x44 cells, 2x pictures
   krd: the terminal answered a U=1 placeholder: pictures are fitted into their cells
   ```

   * 出现 `the terminal answered a U=1 placeholder` → 图是按格子放的。如果仍然不对，错的是**盒子**而不是传输方式：
     去查布局（`krd --wall --pane 137x44 --mock ...`），不要查图形协议。
   * 出现 `refused U=1` / `did not answer the U=1 probe` → 走的是像素路径，图的尺寸取决于 `dpr`：图偏小说明终端
     按设备像素 1:1 画、而 krd 要少了（`--dpr 2` 会变宽）；`--dpr` 调大后图反而**变小**，是终端因体积拒收
     （kitty 的字节预算，`q=2` 会把错误吞掉）：把 `--dpr` 调小。

2. "贴左上、其余空白"是**图比盒子小、且被 1:1 画出**的特征，从来不是 `c`/`r` 写错——会缩放的终端上 `c`/`r` 写错
   只会让图变成奇怪的形状，仍然填满盒子。

   *如果"图要得越大、桌面反而越小"*，那问题不在图：`SCStreamConfiguration` **不会放大**，它把源按自身尺寸
   画好、剩下的补黑。所以请求的像素超过源的像素时，拿回来的就是"桌面缩在一角 + 一圈黑画布"。krd 会把两个数
   都打出来 —— `capture 2431x1518 px asked, 1920x1199 px from a 1920x1200 px source` —— 并把请求夹到源自身
   尺寸（`PanelCapture.fitted`），再由自己放大到面板的精确像素。

3. `--placeholders` / `--no-placeholders` 可以强制任一条路，这是拿同一个终端做对照的办法。

### 23. 只来一帧，然后流永远停住

**根因。** 这一代 macOS 上 `SCStreamConfiguration.queueDepth = 1` 会把流卡死：第一帧送到了，之后没有
任何回调，也不打日志。
**对策。** `queueDepth = 3`（`Capture.swift`）。

### 23a. 点一张图，墙立刻回来还带一句话

**原因。** 点击是生效的：krd 把自己 `exec` 成 `krd --window <id>`，这个镜像一帧都没画出来，于是把面板
交回墙，并在页脚写上原因。常见的几种：

- `the mirror stopped (exit 1) - The user declined TCCs ...`——SCK 的流式那一半（`SCStream`）被拒，
  而一次性那一半（`SCScreenshotManager`，墙的图片用的就是它）是允许的。给运行 krd 的那个终端屏幕录制权限（23b）。
- `the mirror stopped (exit 1) - Screen Recording is off for this terminal`——同一件事，但已经翻译过：
  首帧都没拿到的流会直接说是哪一半被拒了。
- `the mirror stopped (exit 1) - the window closed before it could be shown`——窗口在这一页画出来之后、
  点之前关掉了。滚一下再点。
- `the mirror stopped (exit 1) - Failed during stream due to application connection being interrupted`（`-3805`）
  出现在**某一个特定窗口**上：那个窗口根本没法开流，虽然对它做一次性截图是正常的（卡片上的图就是）。
  很小的窗口、layer-backed 的窗口、以及一些奇怪的窗口会这样（同一个二进制的**第二个进程**也会拿到
  `-3805`，这正是交接用 `exec` 的原因）。krd 内部没有解法：换 `--mirror`（整块屏）或者点旁边大一点的窗口。

**解决。** krd 这边不用做什么，原因就在页脚上。镜像正常跑起来后，在它里面按 `Ctrl-\` 就回墙，并停在
原来那一页——这就是退出窗口镜像的方式。

### 23b. 每块面板都是 `no picture`，页脚让你去给屏幕录制权限

**原因。** macOS 的屏幕录制权限是发给「负责的应用」的。krd 从终端里启动时，这个权限属于那个终端
（Terminal、WezTerm、iTerm、Ghostty），不属于 krd——在系统设置里「加 krd」没有用。没有权限时
`SCScreenshotManager` 对每块面板都返回 `-3801`（`userDeclined`），墙就画成遮罩。
**解决。** 系统设置 → 隐私与安全性 → 屏幕录制 → 勾上你运行 krd 的那个终端，然后重启该终端。
有权限之后 `krd --list` 就能列出窗口。

### 23d. 回到墙之后，某个窗口的画面还盖在上面

**原因。** kitty 的 placement 活得比放它的进程长，而这个流程里没有"离开备用屏"这一步：镜像退出后墙
在**同一个面板**里跑，所以镜像放下的每一块瓦片都还在终端的图库��。墙的会话只清了**字符**
（`beginSession` 里的 `ESC[2J`），没清图，于是墙的标题、卡片、说明全画在一张过期镜像画面**下面**——
看起来就像"分辨率变了"或者"墙没填满"，取决于那个镜像当时在显示什么。
**解决。** 一共三处，因为只做一个不够：两边都会在开场先删掉面板里所有图（`ScreenWriter.clear()`，即
`ESC_Ga=d,d=a`）——`runWall`、`resumeWall`、镜像的实时会话、以及墙的交接；并且镜像在回墙之前**先离开
备用屏**再 `exec`，让墙新建一块屏，而不是继承瓦片当初所在的那块。有些终端会把图挂在屏上，删除命令
应答之后照样继续画（Rex 会，Ghostty 不会），这就是只删图时画面还在的原因。
`WallProcessTests.testTheWallDropsWhateverImagesThePaneHeld` 钉住删除，
`testAReturningMirrorLeavesTheAlternateScreenBeforeTheWallTakesIt` 钉住顺序。

### 23c. 用上墙之后，所有东西都报 `-3805`

**原因。** 同一个可执行文件同时只能有一个活进程当 ScreenCaptureKit 客户端：只要之前那个 krd 还在跑
——另一个终端标签页里的墙、一个忘了退出的镜像、一个终端关了但没死的 krd——新起的 krd 就会对所有流拿到
`-3805`（"failed during stream due to application connection being interrupted"），墙的截图也会是空的。
这不是权限问题，也不是目标窗口的问题：被拒绝的是**第二个**客户端，不管它是谁、抓什么。这也正是点击用
`exec` 而不是 spawn 一个子进程的原因（设计 §12 P3b）。
**解决。** `pgrep -fl krd` 找到旧的，关掉它（终端已经没了就 `pkill -f /path/to/krd`）。一台机器同时只留
一个 krd。

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

### 29b. `--window` 出来一整块黑：那个"窗口"其实是桌面

**根因。** 桌面、壁纸、每块屏的 backstop 在 ScreenCaptureKit 眼里都是窗口，但它们不是*内容*：给它们建
`SCContentFilter` 拿到的是裸的背板层，也就是全黑帧，而且退出码还是 0、什么都不说。实测一帧 480×306：

| 目标 | 不同颜色数 | 3 秒字节 |
|---|---|---|
| `--window <Finder，空标题>` | **24**（146 846 / 146 880 像素是 `(0,0,0)`） | 1 KB |
| `--window <Terminal>` | 1664 | 829 KB |
| `--display 1` | 正常 | 正常 |

**对策。** `--list` 会给这类条目标上 `(backdrop — use --display <n>)`，`--window` 现在直接拒绝它们，
不再画黑屏：

```
krd: window 19 (Finder, title "", layer -2147483603) is the desktop backdrop, not a window —
         ScreenCaptureKit hands back the bare layer, which composites to black.
         Mirror the whole screen instead: krd --display 0
```

判定故意保守：窗口层要**在桌面图标层或更低**，**且**覆盖某块屏的 90% 以上。真实 app 是 0 层，菜单栏 24，
投屏遮罩在最顶上——都不符合；低层但只占屏幕一条的窗口也照常镜像。开 `--debug` 时，若窗口镜像的第一帧
99% 以上是黑的，还会额外打一行提示，用来接住漏过判定的合成层。

### 30. `idle` 一直涨，画面就是不更新

**根因。** 帧状态是用 `CMGetAttachment(sampleBuffer, SCStreamFrameInfo.status, …)` 读的，而这个调用
永远读不到：ScreenCaptureKit 把帧信息放在 buffer 的 *sample attachments* 里
（`CMSampleBufferGetSampleAttachmentsArray`）。于是每次读到的都是 nil，后面的 `?? 0` 又把“没有状态”
当成“状态 0 = complete”——静态屏幕下每个 idle 帧都被记成坏帧，`idle` 永远不动（issue #25）。
**对策。** 从 sample attachments 里读 `status`（`Capture.swift`），并把三种状态分开：没有像素缓冲且状态为
**complete**（或 buffer 根本读不出来）→ `bad`；没有像素缓冲但状态是别的，或者压根没有状态 → `idle`。
现在 `bad` 才真的只表示错误，而且第一个坏帧会把 status 和它实际带的附件键都打进日志。

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

## 6. Headless（`krd ax`）

`krd ax` 的结局都是六个退出码之一，这张表和 `krd ax --help` 里那张是同一张（这里是它的中文译文），
`README.zh-CN.md` 也一模一样：

```text
exit  0  ok —— krd ax doctor 的诊断也是绿的
      2  用法错：不认识的 flag 或子命令，或者值缺失/格式不对
      3  没有辅助功能（Accessibility）权限
      4  辅助功能 API 不应答：Mac 睡了或锁屏、窗口服务器没了、能应答的应用全卡住
      5  没有匹配到：查询、应用或 ref 什么都没找到（krd ax windows 列表为空照样退 0）
      6  节点拒绝了这个动作，或者应用读回来的值不一样

krd ax doctor 诊断不通过时退出 3 或 4（文本和 --json 都一样），而不是 0，所以
krd ax doctor && krd ax windows 是一条在坏机器上绝不会过的健康检查。
```

`--json` 不改任何退出码，也不往 stdout 放散文：失败时 stdout 只有一个对象
`{"ok": false, "error": {"code", "exit", "message", "next"}}`，`code` 是
`usage|permission|environment|notFound|notActionable` 之一，`exit` 就是进程退出的那个数，
`ax` 是 AXError 名字（`cannotComplete`），只出现在权限类和环境类（码 5、6 把名字写在
`message` 里）。所以 `jq -e '.ok'` 做门、`.error.code` 分类、`.error.ax` 定位是哪个辅助功能
调用、`.error.exit` 是进程码。成功时带 `"ok": true` 和该命令原有的字段——`press`/`set` 回的是
它们读回来的状态：
`{"ok": true, "command": "press|set", "ref": "@e7", "label": "…", "before": "…", "after": "…",
"elapsedMs": 3}`（`press` 在元素消失时给 `after: null` 和一个 `note`，写进去了但回读没变时也是
同一个 `note`；`set` 遇到元素消失宁可退 `6` 也不报一个空回读，另外会回写进去的 `value`；`--dry-run` 就是这个
形状加 `"dryRun": true`、没有 `after`/`elapsedMs`）。`--help` 不论带不带 `--json` 都照旧回文本。
老调用方的迁移点就一句：AXError 名字以前是唯一的错误 token，现在在 `.error.ax`。
其余形状见 `krd ax --help`。

### 37. `krd ax` 报「没有辅助功能权限」

**根因。** 授权记在**代码签名**上，而且按二进制算——ad-hoc 重新构建会换 cdhash，昨天授权过的
今天就是陌生人了。另一种常见情况是授权面板里列的是**另一份** krd（比如 `~/.build/` 里的，
而不是 `~/bin/` 的）。
**对策。** `krd ax doctor` 会打印它正在询问的那个路径，并且在这种状态下退出 `3`——它报缺失的
那个授权就是要加的那个。授权那一个：系统设置 → 隐私与安全性 →
辅助功能 → `+` → 选中路径（`Cmd-Shift-G` 可以直接输路径）。如果面板里已经有了，先 `−` 删掉再加，
或者用 `tccutil reset Accessibility com.kkrt.macdesk` 从头来。`krd ax --prompt` 会替你拉起授权弹窗。
注意 `krd ax` 只要辅助功能权限；屏幕录制是镜像模式的。

### 38. 已经授权了，`krd ax` 仍然回 `cannotComplete`

**根因。** 进程还没建立窗口服务器连接，或者根本没有可对话的对象。ssh（Background）会话里
**第一次**无障碍调用必然是这种失败，碰一下窗口服务器之后就好；krd 会自己预热，所以能冒到你面前的
失败是真的：Mac 睡了、停在登录窗口、或者所有候选应用都卡住了。
**对策。** 唤醒/解锁 Mac 再跑。`krd ax doctor` 会把两种情况分开：它打印第一次调用是否失败、
重试是否成功，以及它成功读到的最前台应用。重试成功说明前面那次只是启动噪声。这种状态下
`doctor` 退出 `4`（已授权，但 API 不应答），文本和 `--json` 都一样，所以
`krd ax doctor && krd ax windows` 在这里不可能绿。还有一处毛边：`doctor` 自己打的那段最后一行
是「Run `krd ax doctor` to see which of the two it is.」——那是写给非 `doctor` 子命令的；你已经
在 `doctor` 里了，要行动的是它上面那句（唤醒或解锁 Mac）。`--json` 那一侧不循环：
`.error.next` 绝不会说「run `krd ax doctor`」。

### 39. `krd ax tree` 只有窗口外框，看不到里面的页面

**根因。** Chromium / Electron 默认不构建渲染进程的无障碍树，要等辅助客户端来请求；而在
macOS 27 上，过去用来请求的那两个属性（`AXManualAccessibility`、`AXEnhancedUserInterface`）
在 Chrome 上**设不进去**（实测）。结果就是一棵看起来很正常、只有窗口按钮、没有 `AXWebArea` 的树。
**对策。** 别把「树很小」当成「应用很简单」。浏览器走 CDP（`--remote-debugging-port`）或用
`--force-renderer-accessibility` 启动；Electron 应用同理。详见
[research-ax-text-channel.md](research-ax-text-channel.md) §5.3。

### 40. `--zoom 2` 还是显示整个桌面

**根因。** 裁剪靠 `SCStreamConfiguration.sourceRect`，它是相对于 filter 内容的坐标——display filter 是
显示器，`--window` 是窗口 frame。**副屏**上某些版本要的是全局坐标，于是按显示器原点算出来的裁剪会落到
别处（很老的 macOS 上也可能被直接忽略）。
**对策。** 先看 `--debug` 那行：`source <w>x<h> pt (zoom <f> of <W>x<H> centred <x>,<y>)`。如果裁剪矩形
是对的但画面不对，试 `KRD_ZOOM_GLOBAL_RECT=1`；如果裁剪矩形就错了，那多半是 `--zoom-at` 给了别的坐标系
的点（它要的是全局屏幕点，和 `CGEvent.location` 同一套）。

### 41. `--zoom-follow` 拖动时卡顿

**根因。** 两件事，其中一件已经不成立了。从 #54 起平移走的是 `SCStream.updateConfiguration`
（`Capturer.updateSource`），不再是 `stop()`/`start()`，所以流不再重新协商、画面也不会因此中断。仍然成立的
部分：新裁剪就是新画面，所以下一帧是全屏重绘（所有 tile 变脏）；而且更新后的第一帧仍可能是旧裁剪（它已经
在路上）。
**对策。** 没有要修的东西——连全屏重绘都在意就用 `--zoom-at` 固定视角，或者少放大一档，让指针整段拖动都待在
可视区内。更新被拒绝时日志会写 `krd: could not move the capture window (…); restarting it instead`，krd
会退回到原来的 stop/start 路径。

### 42. `krd ax press @e7` 说 ref 过期了，或者「no snapshot holds @e7」

**根因。** ref 指向某一次 dump 的某一个节点。以下情况它就失效：节点变了（改名、所在窗口重建）、
应用重启过（ref 不跨重启，pid 复用也会被识别出来）、或者打印它的那次 dump 被淘汰了——
`$TMPDIR/krd-ax` 每个窗口只留最近 16 次，重启机器会清空 `$TMPDIR`。
**对策。** 重新 dump，用新 dump 打印的 ref。拿旧 ref 去点是**应该**失败的：另一条路是按住旧路径
点到此刻待在那儿的随便什么东西上。多个窗口混在一起时用 `krd ax press @e7 --snapshot <generation>`
钉住某次 dump，或用 `--app <name>` 收窄到一个应用。

### 43. `krd ax press` 说节点「does not answer press」

**根因。** 这个节点没有 `AXPress` 动作。静态文本、容器都没有；菜单项和复选框在所属窗口没有焦点时
会把自己报成 `enabled=false`——`AXPress` 照样被接受，但什么都不做，回读会把这件事直接打出来
（`before` 和 `after` 一模一样）。
**对策。** `krd ax tree` 会列出每个节点实际有哪些动作（`press`、`showmenu`、`confirm`、`pick`……）。
先把窗口弄到前台（或者先按窗口里的别的东西），再重试。一个动作都没有的节点用这条路驱不动，退回画面。
这个失败是码 `6`（不是 `4`、不是 `5`）：节点找到了，只是它没有 `AXPress` 这个动作——`--json` 里是
`.error.code == "notActionable"`。上面根因里的**另一种**情况不是失败：`AXPress` 被接受了、
`before`/`after` 一模一样时，写是真的送到了，于是退 `0` 并打印「no observable change — some
buttons only act on their target window」（JSON：`"ok": true` 加一个 `note`）。这才是该上报而不是
重试的区别。

### 44. `krd ax set` 写进去了，却以「reads back something else」失败

**根因。** 应用接受了 `AXValue` 又做了规范化：数字框把值夹到范围内、搜索框重排了格式、富文本框把它
包进自己的属性里。
**对策。** 没有坏——退出码是 `6`（见 §6 开头那张表；`--json` 里是
`.error.code == "notActionable"`），上面那行就是应用现在持有的值。读那个值、按它行动；
`krd ax tree --app … | grep <你的文字>` 能从一次新 dump 确认。字段真的只读时，
`AXUIElementIsAttributeSettable` 会提前发现，写请求根本不会发出去。

### 45. 镜像桌面里复制的东西传不到本地终端，或者 `Ctrl-V` 没反应

**根因。** 三件不同的事，日志会告诉你是哪一件：

1. 桥是关的。`--clipboard` 默认 `off` 是故意的——悄悄改写一台机器的剪贴板太意外。`--clipboard=in`
   是镜像端→终端，`out` 是终端→镜像端，`both` 是两边。
2. 你的终端不实现 OSC 52 **写入**，于是 `in` 把序列发出去了但什么也没发生。Rex、Ghostty、kitty、
   WezTerm 支持，Terminal.app 不支持。
3. 你的终端不实现 OSC 52 **读取**（`ESC ] 52 ; c ; ? ST` 请求），于是 `Ctrl-V` 没有内容可粘。这一点
   不是静默的：0.8 秒后日志会出现
   `krd: this terminal did not answer the OSC 52 read, so Ctrl-V has nothing to paste.`，
   兜底是 `--clipboard-paste <file>`——这条路只要目标端 pasteboard 和一次 `Cmd-V`，不需要终端配合。

**对策。** `--debug` 每次同步打一行（`clipboard: 1234 B target -> terminal (OSC 52)`、
`clipboard: 5678 B terminal -> target, Cmd-V posted`），**从不打内容**，所以"哪一半缺了"是可查的。
如果看到 `dropped (limit 2097152 B)`，说明这次剪贴板超过 2 MB——这是有意的：终端会在粘贴前把整段
payload 解码，而 krd 的 stdout 还要跑帧。只桥接文本，不桥接图片。

### 46. 插拔显示器（或改分辨率）之后画面还是旧的形状

**根因。** 一个会话绑在一块显示器上；采集帧的几何只在重建采集流时才会重算，而触发重建的要么是
CoreGraphics 的 reconfiguration 回调（从 GUI 启动的 krd），要么是 2 Hz 的指纹轮询（其它情况——
ssh 会话里的进程收不到那个回调）。
**对策。** 不用做什么——变化大约一秒内会被跟上，`--debug` 会留下两行：选目标时的
`krd: capturing …`，以及重建采集流时的 `krd: capture restarted (N display(s), was M): …`（下面还有
新的 `source … -> … px`）。如果你镜像的那块屏没了，日志会说明改用哪块。两行都没有，说明采集压根没
起来（这跟 `krd ax doctor` 无关，去看 `--debug` 里的 `no displays available`）。

### 47. 画面跑着跑着就冻住了，日志里有一行 `capture stopped`

**根因。** ScreenCaptureKit 返回了 `-3805 Failed during stream due to application connection being
interrupted`——窗口服务器把 krd 底下的采集流断掉了（虚拟机控制台断开、显示器休眠、屏幕录制权限变更都
会这样）。此时所有计数器都还在动、`bad` 一直是 0，除了画面不动之外一切正常：30 分钟浸泡测试里它冻了
19 分钟（issue #44）。
**对策。** 从 #44 起 krd 会自己发现并重启采集流，最多五次，退避 1-2-4-8-8 秒，每次尝试都写一行日志：

```
krd: capture stopped (SCStream 3805: Failed during stream due to application connection being
     interrupted); restarting in 1s (attempt 1/5)
```

如果写的是 `gave up after 5 restarts`，说明和窗口服务器的连接彻底断了：重启 krd（虚拟机的话先确认控制台
还活着）。`probe/soak.py` 就是用来盯这件事的——`callbacks` 超过一分钟不前进时它会把这次运行判失败，
那正是采集流冻住时从外面看到的样子；第一次出现时它还会抓一份栈采样（`<work>/sample.txt`）。

如果画面冻住但日志里**完全没有** `capture stopped`，那是另一种安静的死法（没有错误回调，帧就那么停了）。
注意：**静止**画面本来就一帧都不发，那是正常的，不是卡死（实测：1 秒窗口 0 帧）。krd 真正盯的是「它要过的
那一帧」：平移或重启之后 3 秒没帧就重启采集流。更老的「多久完全没帧」规则要用
`KRD_STREAM_WATCHDOG=<秒>` 显式打开（默认关闭，正因为静止桌面会误触发）。这件事的进展记在
[TESTING §11](TESTING.zh-CN.md#11-浸泡测试全功能开-30-分钟)。

### 48. `--window` 出现黑边，而且点击落点偏左

这两半是同一个 bug（issue #69）：采集尺寸是从 pane 的盒子算的，而盒子比窗口大时 ScreenCaptureKit
**不会放大**——它把窗口 1:1 画在左上角，剩下补黑（1024×678 的窗口放进 70×24 的 pane，实测 31.8% 是黑的）。
指针映射又铺满整个补了黑的盒子，于是画面右边缘附近的点击会被送到左边约 143 pt 之外。

现在帧尺寸 = 源按 `min(boxW/srcW, boxH/srcH, 1)` 缩放后的像素，落脚格子框按 pane 能容纳的最大尺寸算
（`ceil`，锚在 pane 左上，由终端把帧拉进这些格子）；源的宽高比没占满的格子留给终端背景，点在那里会被**忽略**
而不是猜一个点投出去。`--debug` 会说清是哪种情况：

```
krd: source 1024x678 pt -> 1024x678 px in 61x21 cells (the source is smaller than the pane box:
     1024x678 px at 1:1, 27x9 cells left to the terminal)
```

如果修完之后你还看到黑边，那是窗口**自己的内容**就是黑的——用 `--record` 出帧再用看图软件确认，
别靠对着屏幕拍照判断。

`--window` 下的点击在 macOS 26 上还有第二个、互不相干的故障：`CGEvent.postToPid` 能送达键盘事件，
却**静默丢掉鼠标事件**（Safari 和 TextEdit 都是如此），所以镜像窗口根本点不动。现在只要镜像窗口在指针处
处于最上层，鼠标事件就走全局注入（`--debug` 里会写 `-> global tap (the mirrored window is on top)`），
被遮挡的窗口才继续走 pid（issue #17 的情况）。

### 49. 画面自己变糊了，过一会儿又变清晰

这是自适应采集缩放在干活（issue #73）。krd 从全分辨率起步，只在**写侧**跟不上时逐档往下走
（`1 → 0.5 → 0.25`）——慢链路上另一个选择是画面直接不动。链路有余量时会走回来，试探失败也会退回去
（先看到 `... pipe has headroom; scale 0.5 -> 1` 再降档，说明这条链路扛得住 0.5 但扛不住 1）。

在 `--dev` 里能看见（不是 1 的时候状态行会在 fps 旁边显示 `0.5×`），日志里也有（`--debug`，或
`--stats-json` 每秒的 `scale`）。要钉死就 `--scale 1`，要固定另一个值就 `--scale 0.5`。`--bench`、
`--selftest`、`--record`、`--replay` 永远按 1 采集并说明一次，因为它们的输出不能依赖链路——一段帧尺寸
中途变过的录影，文件里没有任何标记。
