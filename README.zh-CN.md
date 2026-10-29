# krd —— 把 Mac 桌面塞进终端

[English](README.md) | 简体中文

[![CI](https://github.com/zzjcool/krd/actions/workflows/ci.yml/badge.svg)](https://github.com/zzjcool/krd/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/zzjcool/krd?sort=semver&label=release)](https://github.com/zzjcool/krd/releases)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](#license)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black)](#环境要求)

> **开发中。** 这个项目还在持续开发，功能在不断加，行为也可能在版本之间变化。欢迎提 issue
> 反馈问题，见 [CONTRIBUTING.md](CONTRIBUTING.md)。

ScreenCaptureKit 抓屏，kitty 图形协议把画面送进终端，鼠标键盘从 stdin 读回来用 `CGEvent` 注入。
没有 VNC、没有编解码器、不开额外端口、不用装客户端 —— 你手上那个 SSH 会话本身就是客户端。

<p align="center">
  <img src="docs/media/demo.gif" alt="krd：SSH 终端 pane 里的一块 macOS 桌面" width="640">
</p>

```bash
ssh -t host krd --fps 20        # 退出按 Ctrl-\
```

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/zzjcool/krd/main/install.sh | sh
```

脚本会下载最新 release（单个通用二进制，Apple Silicon + Intel），校验 sha256，用稳定身份本地签名，
装到 `~/bin/krd`。

```bash
curl -fsSL … | sh -s -- --prefix /usr/local/bin      # 换个安装目录
curl -fsSL … | sh -s -- --version v0.1.1             # 装指定版本
curl -fsSL … | sh -s -- --from-source                # 直接从源码编译
```

细节和失败排查见 [docs/DEPLOY.zh-CN.md](docs/DEPLOY.zh-CN.md)；脚本本身就是普通的 `sh`
（[install.sh](install.sh)）。

## 用法

```bash
krd --fps 20                 # 镜像指针所在的那块屏
krd --list                   # 列出显示器与窗口
krd --window Safari          # 只镜像一个窗口
krd --display 1 --fps 30
krd --no-input               # 只看不动
krd --debug                  # 统计写日志文件，不会打到画面上
```

退出按 **`Ctrl-\`**；`Ctrl-C` 会转发给远程桌面，和真机一致。
完整参数、调优开关和诊断开关在 [docs/ARCHITECTURE.zh-CN.md](docs/ARCHITECTURE.zh-CN.md) 和
[docs/TESTING.zh-CN.md](docs/TESTING.zh-CN.md)。

## 环境要求

- macOS 14 或更新版本
- 终端要支持 kitty 图形协议：**rex**、**Ghostty**、**kitty**、**WezTerm**；Terminal.app 不支持
- 首次运行要授权**屏幕录制**（采集）和**辅助功能**（注入），安装脚本会提示。细节见
  [docs/DEPLOY.zh-CN.md](docs/DEPLOY.zh-CN.md)

## 状态

| | |
|---|---|
| 可用 | 瓦片脏更新（静止画面 0 字节/秒）、指针跟随、左中右三键、双击、滚轮、键盘、窗口级镜像、SSH |
| 粗糙 | 大面积高速运动（还没有编解码器）、Herdr 的图像删除语义 |
| 还没做 | kitty 键盘协议（`Cmd` 组合键、按键释放）、剪贴板、输入法、多显示器热切换 |

## 文档

| | |
|---|---|
| [ARCHITECTURE](docs/ARCHITECTURE.zh-CN.md) | 采集 → 瓦片 → 协议 → 注入，以及命令行与环境变量 |
| [PROTOCOL](docs/PROTOCOL.zh-CN.md) | 每一条发出去的转义序列，以及为什么 |
| [TESTING](docs/TESTING.zh-CN.md) | 自检、瓦片定位标定、怎么验一个新终端 |
| [TROUBLESHOOTING](docs/TROUBLESHOOTING.zh-CN.md) | 36 个现象及其根因 |
| [DEPLOY](docs/DEPLOY.zh-CN.md) | 安装、权限、签名、远端 SSH |

## 参与

见 [CONTRIBUTING.md](CONTRIBUTING.md)；安全问题见 [SECURITY.md](SECURITY.md)。

## 联系

X（Twitter）：[**@zzjcoo**](https://x.com/zzjcoo) —— 修问题最快的方式是提 issue / PR，
X 用来聊想法、看截图。

## 许可

MIT，见 [LICENSE](LICENSE)。
