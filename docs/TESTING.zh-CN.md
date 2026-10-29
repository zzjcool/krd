# 测试与标定

[English](TESTING.md) | 简体中文

这个仓库里没有 XCTest target：真正值得验的东西是一个终端协议加一个截屏框架，所以检查手段就是
(a) 编译一次，(b) 让一张合成画面走真实的渲染管线，(c) 在你真正在乎的那个终端里跑一遍标定流程。
下面每一个开关的存在，都是因为当时有个具体问题必须用事实回答，而不是靠猜。

```bash
swift build -c release                 # the mechanical check
.build/release/krd --selftest          # the renderer, end to end, no permissions
```

CI（[`.github/workflows/ci.yml`](../.github/workflows/ci.yml)）只负责机械的那一半：`swift build -c release`、
只有存在 `Tests/` 目录时才跑 `swift test`（今天没有这个目录），再加一次 universal 的
`--arch arm64 --arch x86_64` 构建，确认发布路径是通的。凡是跟协议、几何或输入有关的东西，仍然必须用下面
这些开关在真实终端上验 —— CI 没有可以往里画图的 pty，也没有可以采集的屏幕。

`--selftest` 全程离线跑：不碰 ScreenCaptureKit、不碰 TCC、不折腾 window server。它假装信号源是一块
1440×2560 pt（竖屏）区域，好让等比适配那条路径被走到；pane 几何从 `TIOCGWINSZ`（或 `--cell`）拿，
然后把 40 帧合成画面推过 `handleFrame` → `TileGrid.dirty` → `emitTile` → zlib → base64 → 终端，
每 250 ms 一帧。你应该看到四个纯色象限、一层暗色棋盘格，以及一条从左扫到右的亮条。看到别的东西，说明
问题在终端或协议，不在采集路径。

selftest 的几种模式都会自己结束（默认图案约 10 s，`KRD_GRID` 约 64 s，`KRD_QUADRANTS` 约 28 s）。它们
不安装任何信号处理器，所以 **Ctrl-C 会把它直接杀掉，不走清理序列**；如果之后 pane 看着不对劲，再启动
一次 krd（进入时会自愈），或者跑 `printf '\033\\\033[?2026l\033[?25h'`。

## 1. `--selftest`

| | |
|---|---|
| 验证什么 | 编码器 → 转义序列 → 瓦片 → 放置，外加布局换算和脏瓦片检测，对着的就是你眼前这个终端 |
| 需要什么 | 一个实现了 kitty 图形协议的终端；**不需要**任何权限 |
| 通过 | 四个象限铺满 pane，亮条平滑移动，没有撕裂或碎片 |
| 失败 | 什么都没出现（协议/终端问题），或者画面偏移/碎裂（几何或放置问题） |

变体（可以和后面几节的环境变量开关组合）：

```bash
krd --selftest --no-input              # --no-input is redundant here but harmless
krd --selftest --cell 17x33            # pin the cell size instead of trusting the pty
krd --selftest --tile 8x4              # more, smaller tiles: exposes per-tile overhead and seams
krd --selftest --fps 30 --tile 32x16   # fewer, bigger tiles
```

时长：40 帧 × 250 ms ≈ 10 s，然后 `endSession()`。

## 2. `KRD_GRID=1` —— 瓦片定位

| | |
|---|---|
| 验证什么 | 第 *n* 块瓦片是不是正好落在单元格 `(tx*tileCols+1, ty*tileRows+1)` 上，占位尺寸也对 |
| 通过 | 每块瓦片都有 3 px 白边，没有缝隙、没有重叠，而且每块瓦片的边框都完整可见 |
| 失败 | 某一边的边框不见了（重叠）、变成双线（缝隙），或者最后一行/一列瓦片位置不对 |

```bash
KRD_GRID=1 krd --selftest --no-input
```

每块瓦片按自己的序号取一个与众不同的颜色（`55 + (index*37)%200`、`55 + (index*71)%200`，蓝色固定
200）加一圈白边，然后同一帧按 200 ms 间隔重发 20 次（这样一旦某次放置丢了，就会表现为某块瓦片在后续
某一趟里消失），最后再保持 60 s，让你有足够时间截图数瓦片。边缘瓦片本来就该小一些 —— 默认 16×8 分块、
137 格宽的 pane，最后一列是 9 格宽，最后一行 4 格高。

## 3. `KRD_QUADRANTS=1` —— 这个终端认哪一种发图方式？

| | |
|---|---|
| 验证什么 | 终端对「让同一张图出现在屏幕上」的四种方式各自的支持情况 |
| 通过 | 你能说清哪几个象限出现了，并且和 krd 实际用的方式（象限 2）对得上 |
| 失败 | 一个都没出现（根本没有图形协议） |

```bash
KRD_QUADRANTS=1 krd --selftest --no-input
```

四块画面间隔 400 ms 依次画出，一个象限一块（各带 6 px 黑边），每种用不同的协议形状：

| 象限 | 发图方式 | 含义 |
|---|---|---|
| 左上 | `a=T` 带 `i=` | 传输并显示，按 id 寻址 |
| 右上 | `a=T` 不带 `i=` | 传输并显示，不带 id |
| 左下 | `a=t` + `a=p`，带 `i=`/`p=`/`C=1`/`c`/`r` | **krd 生产环境用的就是这一种** |
| 右下 | `a=T` 带 `i=`，包在 `?2026` 块里 | 与左上相同，只是走同步块 |

四块画完之后保持 6 s，然后 —— 只有在 `KRD_DELTEST=1` 时 —— 单独发一个
`ESC_Ga=d,i=901ESC\`，并且**不在**任何同步块里，再保持 20 s。

`KRD_DELTEST=1` 回答的是另一个问题：这个终端的 `a=d,i=<id>` 只删掉那一张图，还是把整套图集都删掉？
盯着左上那块（id 900）：它必须活着，同时 id 901 那块消失。如果全都消失了，那这个终端就是 krd 从来
不发逐块删除的原因之一（见 [PROTOCOL §6.3](PROTOCOL.zh-CN.md#63-固定-id不删除)）。

## 4. `KRD_Q=0` —— 看见协议回复

| | |
|---|---|
| 验证什么 | 你发出去的负载到底有没有被接受（`OK`），没被接受又是为什么 |
| 通过 | 任何地方都没有 `EINVAL`/`ENOENT` |
| 失败 | `EINVAL: decompression failed` → zlib 封装错了（用了裸 DEFLATE 而不是 RFC 1950） |

每个转义序列默认都带 `q=2`（所有回复都被吞掉）。`KRD_Q=0` 让它们全都上来，`KRD_Q=1` 只放错误上来。
这个值会原样写进 `q=` 字段，所以协议里定义的任何取值都能用。

回复是从 **stdin** 上来的，而 stdin 同时也是输入源，于是一条回复会被当成按键解析（先是 Alt-`G`，后面
的当文字）。所以永远配 `--no-input` 一起用：

```bash
KRD_Q=0 krd --selftest --no-input      # watch replies in the pane, nothing is typed into the desktop
```

## 5. `KRD_DUMP=<path>` —— 每一个字节，离线看

| | |
|---|---|
| 验证什么 | 究竟发了什么，和屏幕上显示成什么样无关 |
| 通过 | dump 里先是会话框架，然后每块瓦片是 `?2026h`、CUP、`f=32,…,a=t,…,i=<100+n>`、4096 字符分块、`a=p` 放置、`?2026l` |
| 失败 | 不适用：字节都在你手里，自己数就行 —— 这正是它的价值 |

```bash
KRD_DUMP=/tmp/krd-dump.bin krd --selftest --no-input > /dev/null
xxd /tmp/krd-dump.bin | head -40
wc -c /tmp/krd-dump.bin
```

文件在第一次使用时被截断，之后接收每一个 flush 出去的缓冲区，包括自愈序列和 `2J` 清屏，所以它是一份
忠实记录。比较两份 dump（比如 `--tile 16x8` 对 `--full-frame`）是看出协议变化最快的办法。只想要 dump
的时候把 stdout 重定向到 `/dev/null` —— 否则同样的转义序列也会打到终端上。

## 6. `--dry-run` —— 只解析输入，不产生后果

| | |
|---|---|
| 验证什么 | 一次点击或一个按键是否被解析成你期望的坐标/键码，而且是在注入任何东西之前 |
| 通过 | 日志行里的单元格/像素坐标和映射出来的屏幕点都合理 |
| 失败 | 什么都没记（stdin 不是 tty，或者开了 `--no-input`） |

```bash
krd --dry-run --debug              # trace goes to $TMPDIR/krd-<pid>.log, path printed on stderr
krd --dry-run --log /tmp/input.log # or straight to a known file
```

只用 `--dry-run` 是个坑：不给 `--debug`/`--log` 的话，轨迹会走 stderr —— 也就是直接糊在画面上，每写
一行光标就移一次，一滚屏瓦片就碎了。要看的行：

```
input: raw 6 bytes: 1b 5b 3c 30 3b 31 …
input: mouse px(437,812) -> (1204,733) type=1
input: key code=0 flags=256
```

`raw …` 证明终端确实送了东西；映射那一行证明几何是对的；如果第一行有、第二行没有，那要么事件落在了
放置区域之外（点到了画面外面），要么解析器把它丢了。

## 7. 其余开关

| 开关 | 验证什么 |
|---|---|
| `KRD_NOSYNC=1` | 在某台终端上破坏放置的，是不是每块瓦片外面那层 `?2026h/?2026l` |
| `KRD_NO_NSAPP=1` | 复现「ScreenCaptureKit 只送一帧就停」（没有 AppKit 上下文）—— 这是对照组，不是功能 |
| `--full-frame` | 非瓦片路径：一个 image id、每帧一个 `?2026` 块；用它区分「瓦片 bug」和「协议 bug」 |
| `--log <path>` | 写文件日志，但不带统计计时器和输入轨迹 |
| `--debug` | 统计计时器 + 几何 dump + 输入轨迹 + `AXIsProcessTrusted()` |
| `--list` | 屏幕录制权限，以及显示器/窗口枚举，全都在碰任何像素之前 |
| `-v`、`--version` | 手里这个二进制是不是你以为的那个：和 `VERSION` 文件、release tag 对一遍（`scripts/release.sh` 让两者保持同步） |

`stats:` 行，开 `--debug` 时每秒一行（逐字段解释见
[ARCHITECTURE §9](ARCHITECTURE.zh-CN.md#9-诊断开关的接线)）：

```
stats: 113 tiles/s  1 dirty  8 KB  3.88 MB/s  ms[zlib=1 write=0]  2329x1452 px 137x44 cells  idle=3 bad=0
```

怎么读：`tiles/s 0` 且 `dirty 0` 持续好几秒 = 什么都没变（或者什么都没来）；`idle` 一直在涨 = 采集侧
还活着，但屏幕是静止的；`bad` 一直在涨 = 有帧没有像素缓冲区，通常是采集/权限问题；`write` 经常到
几十毫秒 = 终端跟不上这个字节速率，把 `--fps` 调低，或者把瓦片调大。

## 8. 标定一台新终端

每支持一台终端，就按下面的顺序跑一遍，把答案记到 README 的兼容矩阵里
（[中文](../README.zh-CN.md#终端兼容矩阵) / [English](../README.md#terminal-compatibility)）：

1. `krd --selftest --no-input` —— 到底有没有图形协议？（象限 + 扫动的亮条）
2. `KRD_GRID=1 krd --selftest --no-input` —— 定位准不准？（白边、没有缝隙/重叠）
3. `KRD_QUADRANTS=1 krd --selftest --no-input` —— 哪几种发图方式能用？（象限表）
4. `KRD_QUADRANTS=1 KRD_DELTEST=1 krd --selftest --no-input` —— `a=d,i=` 删掉的是一张还是全部？
5. `KRD_Q=0 krd --selftest --no-input` —— 有没有 `EINVAL`/`ENOENT`？
6. `krd --list`，然后 `krd --fps 20 --debug` —— 采集通了、统计非零、画面跟着屏幕动
7. `krd --dry-run --debug` —— 鼠标上报给的是单元格还是像素？（拿已知单元格上的一次点击和日志里的点
   对比；如果出现 `px(...)`，说明这个终端认 `?1016h`）
8. `krd --fps 20 --debug` 加 `--dry-run` —— 不点击、只移动指针：远端光标跟不跟？不跟的话，说明这个
   终端忽略了 `?1003h`（任意移动上报）；点击和拖动仍然可用，悬停不行

## 9. 独立交叉验证（`probe/`）

纯 Python 脚本，只用标准库，不涉及 Swift，也不涉及 krd。要判断「这是终端的问题还是 krd 的问题」，
它们是最快的办法 —— 每个脚本都会自己把过程讲一遍：

| 脚本 | 问题 |
|---|---|
| `probe/kprobe4.py` | 单台终端的能力矩阵：`a=q`、`a=t` PNG、带 `c/r` 的 `a=p`、`x/y`、`X/Y`、`z`、`a=f`、`o=z`、裸 `f=24`、file medium、分块、删除 |
| `probe/kshow.py` | 走朴素的 `t=d` 内联路径画一张 PNG（已知可用的基线） |
| `probe/tile_test.py` | 哪一种定位方式能落在正确的地方（仅 c/r、光标锚定、`x/y`、`X/Y`） |
| `probe/tile_ab.py` | 对四种「把一块瓦片弄上屏」的可行做法做 A/B，都带白边 |
| `probe/rex_delete_probe.py` | 删图 vs 删放置的语义（`a=d,i=`、`a=d,i=,p=`） |
| `probe/kclick.py` | 用一块已知的放置矩形做命中测试，把点击反映射回图像像素 |
| `probe/kdrag.py` | `?1002h ?1006h` 下的按下/拖动/松开 + 滚轮，不重传 |
| `probe/kbench.py`、`probe/kpace.py` | 固定帧率下的管道吞吐与背压 |
| `probe/sck_probe.swift` | `CGPreflightScreenCaptureAccess()`、`CGPreflightPostEventAccess()`、显示器/窗口枚举（在目标 Mac 上跑，看 TCC 是不是问题所在） |

```bash
python3 probe/kprobe4.py > /tmp/p4.log 2>&1 ; cat /tmp/p4.log
swift probe/sck_probe.swift   # on the machine being viewed
```
