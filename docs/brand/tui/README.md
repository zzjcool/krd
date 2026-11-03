# KRD · 寄居蟹

吉祥物定了：**寄居蟹**。壳 = `shell` = 你那个 SSH 会话，桌面住进终端壳里，换壳不换人。

这一页讲的是**怎么画**。造型本身只有一份：`mascot.mjs` 里的路径、渐变、裁切和分组；
下面每一个产物都是从它渲染出来的，没有第二份手抄的蟹。

```
                    docs/brand/tui/mascot.mjs        ← 唯一的源（路径 / 渐变 / 分组 / 8 拍姿态）
                              │
        ┌─────────────────────┼───────────────────────────┬──────────────────────┐
        │                     │                           │                      │
  vector.mjs::svg      vector.mjs::render          swift.mjs ──► MascotArt.swift
        │                     │                           │
  docs/media/mascot.svg   终端精灵图 / lab 页面      MascotRaster.swift（CoreGraphics）
  krd-mark / favicon      （半块 / 字符两态）            │
  krd-favicon（16px 点阵）                          krd 的加载卡（两条传输）

  docs/brand/tui/wordmark.mjs   ← K/R/D 三条路径，同一套胶囊、同一条墨线
              │
        vector.mjs::svg / render / gif
              │
  krd-wordmark.svg · krd-lockup(-stacked).svg · docs/media/krd-social.png · mascot-loading.gif
```

## 文件

| 文件 | 是什么 |
| --- | --- |
| `mascot.mjs` | 造型：`scene()` 一层层写出路径/填充/描边/裁切，`beat(i)` 是 8 拍姿态，`spriteView()` 是取景框 |
| `vector.mjs` | 渲染工具：路径扁平化、自己的光栅器（超采样 + 框滤波）、PNG / GIF / SVG 写出、包围盒 |
| `wordmark.mjs` | 字标：`K`/`R`/`D` 的路径、字母排布（按墨宽推进）、lockup 的基线对齐与 clear space |
| `swift.mjs` | 代码生成：把一个 lod 的场景 + 姿态表写成 Swift（`MascotArt`） |
| `logo-tui.mjs` | CLI：lab 页面、TUI、以及所有静态产物的入口 |
| `../../Sources/krd/MascotArt.swift` | **生成物**，`make mascot` 重写，不要手改 |
| `../../Sources/krd/MascotRaster.swift` | 手写：CoreGraphics 渲染 `MascotArt`，两条传输共用 |
| `krd-wordmark.svg` / `krd-lockup.svg` / `krd-lockup-stacked.svg` | 生成物：字标、横版 lockup、竖版 lockup |
| `../../docs/media/krd-social.png` | 生成物：GitHub 社交预览 1280×640（近黑底） |
| `../../docs/media/mascot-loading.gif` | 生成物：加载卡的四个图片帧（36×45 dot，整数倍放大） |

## 三个尺寸（lod）

| lod | 用在哪 | 画什么 |
| --- | --- | --- |
| `hi` | README 的 SVG、PNG、社交图（512px 起） | 69 层：壳的厚度/内暗面/螺旋脊/高光、四条腿、钳、眼柄、腮红、天线 |
| `lo` | 终端：36 dot 的半块卡、36×45 的图片卡、`--mark` 64px、`--favicon` 16px | 22 层：壳 + 一圈螺纹 + 开口，身体 + 两只大眼 + 嘴；**腿、钳、天线在这个尺寸会糊成一团，故意不画** |

只有两个 lod，没有"小尺寸另画一份"的第三个：`lo` 就是给 36 dot 设计的，16 px 和 64 px 都用它。
`--mark` 是 64 dot 的精灵图（SVG）；`--favicon` 是 14 dot 的精灵图画在 `#080a10` 圆角 tile 上
（点阵，一 run 一个 `<rect>`、`shape-rendering="crispEdges"`）——透明底的 16 px 蟹在浅色标签栏上会散掉。

## CLI

```sh
node logo-tui.mjs                    # 全屏 TUI：8 拍动画、s 拟物/字符、空格暂停、1-8 跳拍、q 退出
node logo-tui.mjs --test             # 布局自检：8..160 列 × 4..40 行，每行严格 cols 宽
node logo-tui.mjs --frames           # 8 拍，按加载卡的画法
node logo-tui.mjs --art              # 46×23 的字符版寄居蟹
node logo-tui.mjs --dump             # 两个 lod 的半块图
node logo-tui.mjs --banner           # --help 的 5 行大写字标
node logo-tui.mjs --shot lab.html    # 一页把每一档尺寸、明暗两态都排出来
node logo-tui.mjs --plain --beat 3   # 管道里只出一张卡（字符版）；默认是半块版

node logo-tui.mjs --svg  mascot.svg  --px 680              # 只画蟹，裁到墨边，透明
node logo-tui.mjs --png  mascot.png  --px 680 [--bg #0d1117]
node logo-tui.mjs --mark krd-mark.svg --px 64
node logo-tui.mjs --favicon krd-favicon.svg --px 16
node logo-tui.mjs --beats mascot-loading.png --px 256      # 图片卡的四帧并排
node logo-tui.mjs --gif  mascot-loading.gif --cell 8       # 同样四帧，按终端放大的整像素
node logo-tui.mjs --wordmark krd-wordmark.svg --px 960     # 字标，裁到墨边
node logo-tui.mjs --lockup krd-lockup.svg --px 960         # 横版：蟹站在字标的基线上
node logo-tui.mjs --lockup krd-lockup-stacked.svg --px 640 --stacked
node logo-tui.mjs --social krd-social.png --px 1280        # 2:1 社交预览，近黑底
node logo-tui.mjs --swift Sources/krd/MascotArt.swift      # 生成 Swift
node logo-tui.mjs --write                                  # 重写全部产物（= make mascot）
node logo-tui.mjs --verify                                 # 比一遍，过期就红（= make mascot-check）
```

零依赖，Node 18+。

## 加载卡（krd 自己画的那张）

首帧到达之前显示，两条传输，**由 `a=f` 探针决定，不猜**（#217 / 设计 §5.1）：

- **终端会播动画**：一张 36×18 的图片，四帧 `a=t`/`a=f`，帧距 220 ms，一次发完 + 一次放置，
  之后 **0 B/tick**。整卡 ~8.6 KB（3 秒窗口，含放置和两行字），预算 4 KB/s。
- **终端不会**：36×36 dot 的 `▀` 半块，110 ms 一跳，8 拍循环，~23 KB/tick——**故意保持原样**，
  这是"改之前"的对照数字，降级路径不允许顺手改画。

两拍是同一只蟹：0.05 → 0.45 → 0.8 → 1（全伸出）→ **1（眨眼）** → 1 → 0.8 → 0.45。
图片卡只发偶数拍（0/2/4/6），4 × 220 ms = 880 ms，正好是原来 8 × 110 ms 的一轮。

图片卡的像素高度由调用方量到的 cell 推出来（`36 · cellH / (2 · cellW)`，8×20 的 cell 是 45 行），
所以图片自己的长宽比等于它占的 cell 盒的长宽比——拉伸型和等比缩放型的终端看起来一样。

## 字标与 lockup

`KRD` 不是排出来的字体，是照着蟹画出来的：每个字母都是 `taper()` 扫出的胶囊（和腿、眼柄、钳臂同一个
肢体工具箱），一个大写高 200、一个笔画 30（15%），一条 `INK.line` 描边压在填色下面（只露出外侧一半，
和蟹的轮廓同一个规则）。`K` 的斜臂、`R` 的腿带一点弯——直线单线字会被读成字体，弯的会被读成这张画。

排布按**墨宽**推进：每个字母先量自己含描边的墨盒，字距 `GAP = 46`（0.23 个大写高），所以字母之间
的空白是设计值，不是字体度量碰巧留下的。`R` 的碗收到 0.56 高度，腿从碗肩下面出来；`D` 只有一个
半椭圆，是最宽的字母。

lockup 把两个场景放一起（`translate` 只动路径、渐变和群组 pivot，不动画法）：

- **横版**：蟹的墨底 = 字标的基线，蟹墨与 `K` 墨之间 `LEAD = 64`（0.32 个大写高）。蟹放大 1.2 倍：
  它的体量比大写高小，1:1 会看起来像字旁边的一个小图标。
- **竖版**：蟹在上、字在下，中轴对称，中间 `STACK = 48`；蟹缩到字宽的 56%。
- **clear space**：四周 0.14 个大写高（28 单位），`--lockup` 的 viewBox 就是这个矩形。

`--social` 把横版 lockup 放进 2:1 的 1280×640、`#080a10` 底，四周留白由 viewBox 决定（不是裁剪）。
GitHub 的社交预览图要在仓库设置里手动上传，仓库里这份就是上传用的。

## 配色

自然色，不是品牌蓝：壳沙色 `#f3dfb8`、螺纹 `#c4884e` / `#8e643a`、身体珊瑚 `#f4845a`
（渐变到 `#d8603c`）、眼睛奶白 `#fffaf2`、墨 `#3b2416`、纸 `#080a10`。
品牌蓝 `#5eb8ff` 只留**瞳孔里那一点**——一眼是寄居蟹，第二眼才发现那是 krd 的蓝。

## 生成物不许漂

```sh
make mascot         # 重画：MascotArt.swift + docs/media/* + docs/brand/tui/*.svg + shot.html
make mascot-check   # 重新生成一遍比 cmp，再跑 lab 的自检；生成物过期就红
```

`MascotArt.swift` 是生成物：改造型去改 `mascot.mjs`，然后 `make mascot`。
`MascotArtTests` 守的是另一半——生成出来的东西能不能画（每条 paint 都能解析、每个 group 都能解析、
每个颜色都在调色板里、36 dot 下墨量在 25%~55%、四帧互不相同、眨眼真的闭上、纸色在角上精确）。

## 还没做

- TUI 抓屏版的动画 GIF（半块卡、终端质感）——现在这份 GIF 是图片卡的四帧 `a=f`，是产品会播的那份；
  抓屏版要录终端，生成器不做
- `--banner`（`--help` 的 5 行字符字标）还是手写的方块字，没有跟着 `wordmark.mjs` 走
- 社交预览图上传到仓库设置是手动步骤，`make mascot` 只负责把它画对
