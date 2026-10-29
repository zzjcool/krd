# 部署

[English](DEPLOY.md) | 简体中文

krd 就是一个自包含的 Mach-O 二进制。没有要安装的东西，也没有会自己启动的东西：把文件拷过去，
一次性授权两项权限，之后想在谁的终端上看桌面，就在哪条 SSH 会话里跑它。会话结束它就退出。

## 0. 一条命令

在**被观看**的那台 Mac 上（如果你要镜像的是自己这台，就在本机）：

```bash
curl -fsSL https://raw.githubusercontent.com/zzjcool/krd/main/install.sh | sh
```

它会解析最新 release、下载 `krd-vX.Y.Z-macos-universal.tar.gz`、校验 sha256、用你的
`Apple Development` 身份签名（没有就退到 ad-hoc），装到 `~/bin/krd`。
可选参数：`--prefix DIR`、`--version vX.Y.Z`、`--sign IDENTITY`、`--from-source`。
下面写的就是这个脚本干的事，外加必须手工处理的情况。

## 1. 目标 Mac 需要什么

- macOS 14 (Sonoma) 或更新。
- 打开**远程登录**：系统设置 → 通用 → 共享 → 远程登录。这一步需要图形界面（或用管理员跑
  `systemsetup`）；`deploy.sh` *不会*替你做。
- 其它什么都不用：不需要 Swift 工具链、不需要 Python、不需要 Xcode —— 二进制是整块拷过去的。
- 大约 5 MB 磁盘空间。

*看*的那台机器需要一个实现了 kitty 图形协议的终端（见 [README 的兼容矩阵](../README.zh-CN.md#终端兼容矩阵)）
和一个 `ssh` 客户端。

## 2. 部署

在一份本仓库的检出里，于一台装了 Xcode command line tools 的 Mac 上：

```bash
./deploy.sh user@host                    # → 目标机的 ~/bin/krd
./deploy.sh user@host /usr/local/bin/krd # 指定目标路径
```

脚本做了什么：

1. `swift build -c release --arch arm64 --arch x86_64` —— 一个 universal 二进制，目标机是什么架构都行。
2. 用 `install.sh` 用的同一个身份签名（`security find-identity -v -p codesigning` 里第一个
   `Apple Development: …`；可用 `KRD_SIGN_IDENTITY=…` 覆盖），并强制 identifier 为 `com.kkrt.macdesk`。
3. 打印架构和体积，然后用 `cat | ssh "cat > …"` 把签名过的文件流式拷过去，签名逐字节保留
   （有些服务器的 `scp`/`sftp` 是关的）。
4. 打印安装后的字节数，以及从 `codesign -dv` 里取出的 identifier。

远端目录必须事先存在 —— `cat > ~/bin/krd` 不会顺手创建 `~/bin`：

```bash
ssh user@host 'mkdir -p ~/bin'
./deploy.sh user@host
```

想走手工路线（同架构，不编 universal）也可以：

```bash
scripts/install-from-source.sh      # 本机编译、签名、装到 ~/bin/krd
scp ~/bin/krd user@host:~/bin/krd   # 或者：cat ~/bin/krd | ssh user@host 'cat > ~/bin/krd'
ssh user@host 'codesign -dv ~/bin/krd 2>&1 | head -3'
```

复制一个*已签名*的文件没问题；但在目标机上重新签名不行（见 §4）。

### 本机没有工具链：用 Release 里的 tarball

每次发版（`v*` tag 触发 `.github/workflows/release.yml`）都会在 Releases 页面上传
`krd-vX.Y.Z-macos-universal.tar.gz` 和对应的 `.sha256`。那个二进制是 CI 编的，**没有**用任何本地身份
签名，所以第一次跑之前自己签一下 —— TCC 授权挂在签名上，未签名/ad-hoc 的二进制每重编一次都要重新授权：

```bash
curl -LO https://github.com/zzjcool/krd/releases/download/vX.Y.Z/krd-vX.Y.Z-macos-universal.tar.gz
shasum -a 256 -c krd-vX.Y.Z-macos-universal.tar.gz.sha256    # 或者自己跟一眼
tar xzf krd-vX.Y.Z-macos-universal.tar.gz && cd krd-vX.Y.Z-macos-universal
codesign --force --sign "Apple Development: …" --identifier com.kkrt.macdesk krd
cat krd | ssh user@host 'cat > ~/bin/krd && chmod +x ~/bin/krd'
ssh user@host '~/bin/krd --version'      # 应该是 X.Y.Z
```

## 3. 第一次运行：两项 TCC 授权

屏幕录制和辅助功能是两项独立授权，而且都是「每台机器一份」：

| 授权 | 用来做什么 | 没有它会怎样 |
|---|---|---|
| 屏幕录制 | ScreenCaptureKit 采集，以及 `--list` | 采集报 `-3801 user declined`，或者 pane 一直是黑的 |
| 辅助功能 | `CGEvent` 注入（鼠标、键盘） | 画面正常，但任何操作都没反应 |

这一步请**在目标 Mac 上、用它自己的图形界面终端**（Terminal.app 之类）做一次，不要从 SSH 会话里做 ——
macOS 未必会把弹窗归给一个由 `sshd` 拉起的进程，而你看不见的弹窗等于没法点「允许」：

```bash
~/bin/krd --list        # 触发「屏幕录制」弹窗 → 允许
~/bin/krd --fps 20      # 触发「辅助功能」弹窗 → 允许（画面会立刻出来）
# Ctrl-\ 退出
```

如果 macOS 压根不弹窗，就手动加：系统设置 → 隐私与安全性 → **屏幕录制** → `+` → 选中 `~/bin/krd`
（文件对话框里按 `Cmd-Shift-G` 可以直接输路径）→ 打开开关；然后到**辅助功能**里同样加一次。授权成功后
两个面板里都会列出这个二进制；过期的条目用 `−` 删掉。

授权卡住时，也可以用命令行把记录清掉重来：

```bash
tccutil reset ScreenCapture com.kkrt.macdesk
tccutil reset Accessibility com.kkrt.macdesk
```

（`tccutil` 不需要 sudo；这里的 identifier 就是 `install.sh`/`deploy.sh` 冻住的那个。）

`--debug` 会在日志里记 `krd: accessibility trusted=true|false`，采集失败也会把具体错误写进日志 ——
先看日志，别猜。

## 4. 签名稳定性（无声失效的那一半）

macOS 把这些授权记在**代码签名**上，不是路径上。于是：

- **不要 ad-hoc 签名**（`codesign -s -`）。每次编译都是新的 cdhash，TCC 记录对不上，
  ScreenCaptureKit 返回 `-3801`（或者 pane 全黑而屏幕上没有任何错误）。只有在完全找不到身份时
  `install.sh`/`deploy.sh` 才会退到 ad-hoc，而且会警告。
- **identifier 必须冻住**（`com.kkrt.macdesk`）。TCC 记录挂在它上面；改掉它 —— 哪怕只是改成一个「更好看
  的名字」—— macOS 就会把它当成一个新 App 重新要授权。
- **安装路径保持稳定。** 就地覆盖文件没问题，挪到别的目录不行（你会得到第二条 TCC 记录，而第一条指向
  空气）。
- **绝对不要在目标机上 `strip`、重签或 `xattr` 这个二进制。** 本地重编、本地重签、再拷一次。
- 所以升级流程是：停掉 krd → `./deploy.sh user@host` → 再运行。授权会保留，因为身份和 identifier 都没变。

确认装上去的到底是什么：

```bash
ssh user@host 'codesign -dv ~/bin/krd 2>&1 | head -5; file ~/bin/krd; ls -l ~/bin/krd; ~/bin/krd --version'
```

期望看到：`Identifier=com.kkrt.macdesk`、用你自己的身份签的名（不是 `Signature=adhoc`）、
`Mach-O universal binary with 2 architectures`、和 `deploy.sh` 打印一致的字节数，以及 `VERSION` /
`Sources/krd/Version.swift` 里的那个版本号。

## 5. 日常使用

```bash
ssh -t user@host ~/bin/krd --fps 20 --debug --log ~/krd.log
```

- **`-t` 是必须的。** stdin 没有 tty 时 krd 会禁用输入并退回 80×24 格。
- `--log ~/krd.log` 把日志固定在一个你能读的位置（另一个会话里 `ssh user@host tail -f ~/krd.log`）。
  不给的话，`--debug` 会写到目标机的 `$TMPDIR/krd-<pid>.log`，并在 stderr 上把这个路径打一次。
- `--fps 20` 是默认值；局域网可以调高，慢链路调低。瓦片让字节率只和真正变化的面积有关，所以 `--fps`
  主要买的是手感，不是带宽。
- 网络断了 pty 就死，krd 跟着结束（它处理 `SIGHUP`/`SIGTERM` 并恢复终端）。在不可靠链路上跑长会话时
  加 `-o ServerAliveInterval=30 -o ServerAliveCountMax=3`，让会话早点干净地断开，而不是挂着不动。

之后就当本地桌面用：点击、拖动、滚轮、打字。Ctrl-\\ 退出，终端状态是干净的。

## 6. 运维注意

- **你不启动，它就不存在。** krd 就是你 SSH 会话里的一个前台进程；你走了它也就没了。没有其他东西要安装、
  要启用、要保活。
- **目标机不开任何端口。** 一切都走 SSH 会话，所以不需要防火墙规则，也不存在「谁能连上这个服务」的问题 ——
  连 SSH 都进不来的人本来也碰不到它。
- **睡眠会中断画面。** krd 不会阻止 Mac 睡眠；会话睡眠或锁屏之后 macOS 就不再给屏幕内容了（黑帧）。
- **一个会话一个进程。** 每条 SSH 会话启动自己的 krd、自己的一条采集流 —— 两三个观看者没问题，再多就浪费了。
- **卸载**就是 `rm ~/bin/krd`，再去隐私与安全性里删掉那两条记录。没有收据、没有 plist、没有缓存要清。

## 7. 部署到多台 Mac

```bash
for host in mac-mini@10.0.0.11 macbook@10.0.0.12; do
  ssh "$host" 'mkdir -p ~/bin'
  ./deploy.sh "$host"
done
```

每台仍然要各自做一次 TCC 授权（§3）—— 授权是按机器记的，哪怕签名身份完全相同也不能转移。
