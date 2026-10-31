# 决策：Rust，以及为什么这个选项现在很便宜

**状态：** 已决定（2026-10-30），只能通过 §4 的触发器重新讨论。
**归属 issue：** [#9](https://github.com/zzjcool/krd/issues/9)。**前置：** #21 / #43 / #46（`krdcore`）。
**English:** [decision-rust.md](decision-rust.md)

## 1. 决定

现在不做。但「现在不做」只有在「搬迁不再是重写」时才诚实——而 #21 之后这就是事实：整个字节契约
（瓦片、level 策略、zlib、逃逸序列组装）和整个输入协议（CSI/SS3 状态机、`Event`）都在 `krdcore`
里，没有任何 Apple import，并且被两份提交进仓库的 fixture 钉住。将来的搬迁是**替换这个模块**，
不是重新推导它。

这个 issue 原来的说法——「语言是 1.2×，算法是 33×」——依然正确，也依然会被误读：33× 是三个杠杆的
**乘积**，其中两个已经发货。本文用今天存在的测量替换那个心智模型。

## 2. 桌上到底还剩多少

下面的数字来自参考笔记本（MacBookPro18,3，10 核）上 `bench/bench.py` 的实跑，`main` @ `e82844d`，
16 项预算检查全过。完整报告：`bench/report.md`；方法见 [BENCHMARK](BENCHMARK.md) §7。
单帧预算是 50 ms（20 fps）。

| 场景 | 编码 p50 | 编码 p99 | p99 占 50 ms 预算 |
|---|---:|---:|---:|
| `char`（打一个字符） | 1.31 ms | 1.64 ms | 3.3 % |
| `line`（一行文本） | 1.44 ms | 2.52 ms | 5.0 % |
| `drag`（拖窗口） | 4.06 ms | 4.44 ms | 8.9 % |
| `gradient` | 3.57 ms | 4.01 ms | 8.0 % |
| `full`（整屏变化） | 7.52 ms | 7.91 ms | 15.8 % |
| `ui`（列表滚动） | 6.22 ms | 9.14 ms | 18.3 % |
| `photo`（哈希噪声） | 24.49 ms | 30.53 ms | 61.1 % |

真正每秒跑 20 次的是 `char`/`line`/`drag`：**≤ 5 % 预算**。Rust 那 1.2× 是在 #2 之前的单线程编码器
上测的；套到今天剩下的部分，它是个**上界**：

| 场景 | 今天 p99 | 编码器快 1.2× 之后 | 省下 |
|---|---:|---:|---:|
| `char` | 1.64 ms | 1.37 ms | 0.27 ms（帧间隔的 0.5 %） |
| `line` | 2.52 ms | 2.10 ms | 0.42 ms（0.8 %） |
| `full` | 7.91 ms | 6.59 ms | 1.32 ms（2.6 %） |
| `photo` | 30.53 ms | 25.44 ms | 5.09 ms（10 %） |

`photo` 看起来是例外，而它恰恰是语言帮不上的那种：这一帧 payload 9.68 MB、线上 13.58 MB，zlib 对它的
压缩比是 **~1.00×**（10.15 MB / 10.14 MB 原始像素），而本地 pty 的上限是 103.6 MB/s——这个场景现在
就跑 ~8 fps，CPU 在等管道。[research-photo-bandwidth](research-photo-bandwidth.zh-CN.md) §0 里量过
那里的杠杆：zlib 之前做 16 位量化，线上体积 **1.57×**；采集端 ½ 缩放 **4.56×**；真实照片（不是哈希
噪声）今天 6.32 MB、16 位下 1.27 MB。**下一个大赢是更少的字节，不是更快的语言。**

所以搬迁剩下的收益是用户真看得见的那些帧上的 0.3–1.3 ms，即帧间隔的 0.5–2.6 %；而最差的那类内容
受限于管道，不是编码器。

## 3. 搬迁到底要付什么

不是「重写 krd」，而是「按 #21/#45 建立的边界替换 `krdcore`」。

### 3.1 Rust 侧要实现的公开面

| 领域 | 今天是什么 |
|---|---|
| `TileGrid` | `make(paneCols:paneRows:cellW:cellH:aspect:tileCols:tileRows:)`、`rect(_:_:)`、`extract(_:rect:)`、`dirty(previous:current:grid:)` |
| 瓦片 | `CompressedTile`、`ScreenWriter.compress(index:rect:pixels:level:)`、`zlibCompress`（经 libz 的 RFC1950） |
| 策略 | `LevelPolicy`（`level(for:)`、`observe(index:ratio:)`）、`PixelFormat`、`SyncMode` |
| writer | `beginSession`/`endSession`、`resize(tiles:)`、`beginFrame`/`endFrame`/`nudge`、`emit(_:sync:)`、`clear`、`writeRaw`、`writeMouseReporting`、`writeKeyboardProtocol`、字节计数 |
| 输入 | `InputParser`（缓冲、CSI/SS3/OSC 成帧、UTF-8 长度）与 `Event`；`Keys`、`Keyboard.plan`（`--ime`）、`Modifiers` |

Swift 侧对外的 API 一行都不用改：`Package.swift` 换掉 `krdcore` 的实现，`krd` 继续 import 它。

### 3.2 FFI 边界，以及一次调用多少钱

Swift 留住 OS 那一半——ScreenCaptureKit、`NSApplication`、`CGEvent`/`postToPid`、termios、
`NSPasteboard`、AX——因为那部分跟语言无关，永远得存在。Rust 只在四处被调用：

| 调用 | 频率 | 成本 |
|---|---|---|
| `krd_encode_begin_frame(enc, out_fd)` → 帧直接落到 tty | 每帧一次 | 一次 C 调用（~10 ns），`write(2)` 由 Rust 直接做，字节不用绕回 Swift |
| 帧以**指针 + stride** 传入（SCK 的 BGRA，不拷贝） | 每帧一次 | 10 MB 不复制；Rust 直接读采集器已经产出的缓冲 |
| `krd_parse(p, bytes, len, cb, ctx)` → 每个按键/点击一个事件 | 每次 `read(2)` 一次 | 一次调用 + 每事件一次回调（~100 ns；拖拽约 60 事件/秒） |
| `krd_encoder_new`/`_free`、`krd_parser_new`/`_free` | 每会话一次 | 可忽略 |

峰值估计：**不到编码预算的 1 %**——也就是边界本身既不是说不的理由，也不是说是的理由。（唯一真正的
坑：回调不能每个事件都分配一个 Swift 闭包；事件结构体是 POD，按值传。）

### 3.3 必须重建的验证（这才是真成本）

- `Tests/krdcoreTests/Fixtures/selftest-80x24-17x33-l6.dump` —— Rust 编码器必须**逐字节**复现
  （sha256 `2e893d04…`）：同一个 zlib、同一套 level、同样的逃逸顺序。
- `Tests/krdcoreTests/Fixtures/input-trace.dump` —— Rust 解析器必须复现七组喂入序列的规范 trace。
- 两条 `--debug` 层的对等检查（渲染 dump、输入 trace）要对着 Rust 构建重跑。
- CI：一条 Rust 工具链、一个 `cargo test` 作业、两份 fixture 各跑两遍（Swift、Rust）。
- 预算套件（`bench/budget.json`，16 项检查）作为回归闸门。

这是一天 CI 工作量加上搬迁本身，而不是 issue 当初估的「3 周重写」。

## 4. 什么会改变答案（可观测的触发器，不是日期）

1. **编码 p99 超过 8 ms**（预算的 16 %），针对 `line`、`char` 或 `drag`，按 [BENCHMARK](BENCHMARK.md)
   §7 的流程在参考笔记本上测，且**连续两个版本**都超。今天：2.52 / 1.64 / 4.44 ms。
   不包括 `photo`——那一类受管道限制（§2），更快的语言动不了它。
2. **分配/COW 那一类 bug 出现第二个**——也就是「修法是少拷一点」而不是「算得快一点」的 bug。#1 是第一个。
3. **开始写手写编解码器或快速 deflate**：那种代码要么用 Rust 写，要么就别写；它也是唯一剩下的**带宽**
   杠杆（#26）。
4. **多平台回到路线图**：那时 OS 那一半不再「默认 Swift」，整个算式就变了——但要注意 §5 说的：脆的
   是 run loop，不是编码器。

## 5. 明确不做的

- **现在上 Rust。** 省下用户看得见的帧上 0.3–1.3 ms，换来第二条工具链、第二个 CI 作业、两份要一直
  保持绿的 fixture，以及一个失败形态是黑屏的边界。
- **纯 Rust 二进制。** `ARCHITECTURE.md` §4 是这个仓库唯一被证明脆弱的地方（少一个 AppKit 上下文就
  一帧都不给），而 TCC 授权绑定代码签名。换语言并不消除这个风险，所以它买不到 shim 买不到的东西。
- **`libdeflate` 式快速 deflate 替代。** #8 已经否掉，现在依然成立：它不需要 Rust——一个
  `systemLibrary` shim 就够；而且 #26 之后有意思的杠杆是更少的字节，不是更快的压缩器。
- **重写 OS 那一半。** ScreenCaptureKit、CGEvent 和 AX 通道，无论 core 变成什么语言，都留在 Swift。

组合说明：这个选项之所以还开着**正是因为** `krdcore` 已经存在。在 #21 之前，同样的决定要付一次重写
的代价，本文就只能靠口味论证；现在它靠的是对两份已经通过的 fixture、一天 CI 工作量的论证。

将来真搬的话代码放哪，写在 `CONTRIBUTING.md`（「If a Rust core ever lands」）里，免得从零再吵一遍。
