# Kzhento

> 由 ZIT 小圳工作室打造的基于 Kubuntu 的操作系统，源自 [ZhenTo](https://github.com/zitzhen/zhenTo)。

[English](README.md) · [简体中文](README_zh-cn.md) · [繁體中文](README_zh-tw.md)

Kzhento 是一款基于 **Kubuntu 26.04.1 LTS "Resolute Raccoon"** 定制的 Linux 发行版。本仓库的代码复制自 ZhenTo：其 shell 脚本对原版桌面镜像进行品牌重塑，预装了一组开发工具，并生成可直接写入 U 盘的 **仅 UEFI** 启动/安装 ISO 镜像。

整个镜像由 shell 脚本组装完成——旧的 Cubic 依赖已被移除。从解压官方 ISO、在 `chroot` 中打补丁，到重新打包成可启动镜像，一切都可以在本仓库中复现。

> **关于源代码的说明：** 脚本本身未做任何修改。其中的默认值与运行时字符串（`BASE_ISO`、卷标、产物文件名、`/etc/os-release`、GRUB 菜单）仍沿用 ZhenTo/Ubuntu 的标识。构建时请通过 `BASE_ISO` 传入你自己的 Kubuntu ISO。

| | |
|---|---|
| **当前版本** | 0.1.0 |
| **基础镜像** | Kubuntu 26.04.1 Desktop（amd64） |
| **固件** | 仅 UEFI（不支持传统 BIOS） |
| **许可证** | [AGPL-3.0-only](LICENSE) |
| **主页** | https://github.com/zitzhen/Kzhento |
| **问题反馈** | https://github.com/zitzhen/Kzhento/issues |

---

## 目录

- [特性](#特性)
- [仓库结构](#仓库结构)
- [构建 ISO](#构建-iso)
  - [准备工作](#准备工作)
  - [快速构建](#快速构建)
  - [构建模式](#构建模式)
  - [环境变量](#环境变量)
- [使用 ISO](#使用-iso)
- [下载发行版](#下载发行版)
- [测试](#测试)
- [持续集成](#持续集成)
- [参与贡献](#参与贡献)
- [许可证与致谢](#许可证与致谢)

---

## 特性

- **品牌重塑** —— `/etc/os-release` 和 GRUB 启动菜单是 Kzhento 的品牌入口（当前仍沿用继承而来的 ZhenTo 字样）。
- **预置 Logo** —— 构建时从 [kzhento-icon](https://github.com/zitzhen/kzhento-icon) 下载 Kzhento Logo（固定 commit + SHA256 校验），安装到 `/usr/share/backgrounds/kzhento/`，仓库中不再存放二进制图片。
- **仅 UEFI 镜像** —— 向 ISO 追加单个 EFI 系统分区，并使用 `xorriso` 生成启动项。
- **预装开发工具** —— `curl`、`git`、`zsh` 和 [patchsplit](https://github.com/zitzhen/patchsplit)（来自 `ppa:zitzhen/patchsplit` PPA）。
- **所有账户使用 zsh** —— 已有账户切换为 `/bin/zsh` 并安装启用 Starship 的 `.zshrc`，`/etc/default/useradd` 让新建账户使用同一 shell。
- **Kzhento 桌面安装器** —— 来自 [zhento-desktop-install](https://github.com/zitzhen/zhento-desktop-install) 的 `ubuntu-desktop-bootstrap` snap 被预置到镜像中。在真实系统中直接安装；在 `chroot` 内则通过一次性 systemd 服务在首次启动时完成安装。
- **感知分层的补丁机制** —— 仅修改默认安装源的基础 squashfs 层，语言层和 enhanced-secureboot 覆盖层保持不变。
- **校验和与验证** —— 重新生成 `md5sum.txt`，CI 为每个发行版发布 MD5 和 SHA256 校验文件。
- **自动化 CI** —— Pull Request 由 lint/单元测试把关；tag 构建会生成 GitHub 草稿 Release，并拆分为小于 2 GB 的压缩包。

## 仓库结构

```text
.
├── build.sh                  # 主 ISO 构建脚本（解压 → chroot → 重新打包）
├── edit-grub/
│   ├── grub.cfg              # GRUB 菜单（Kzhento 品牌；沿用 ZhenTo 菜单项）
│   └── replace-grub.sh       # 将菜单写入目标 grub.cfg（自动备份）
├── edit-os-release/
│   ├── os-release            # /etc/os-release 品牌信息（Kzhento；沿用原有值）
│   └── edit.sh               # 将文件写入 /etc/os-release
├── edit-terminal/
│   └── edit-terminal.sh      # 将所有已有账户切换为 zsh 并安装 Kzhento 的 .zshrc
├── edit-logo.sh/
│   └── edit-logo.sh          # 构建时下载并安装 Kzhento Logo
├── edit-etc-default-useradd/
│   ├── edit-etc-default-useradd.sh # 向 /etc/default/useradd 写入 SHELL=/bin/zsh（新建账户）
│   ├── useradd               # Kzhento 的 /etc/default/useradd
│   └── .zshrc                # Kzhento 的 ~/.zshrc（Starship 提示符）
├── install-app/
│   ├── ppa.list              # 构建时启用的额外 PPA
│   ├── curl.sh, git.sh, zsh.sh, patchsplit.sh
│   └── Installer.sh          # 桌面安装器（snap）配置
├── scripts/
│   └── download-release.*    # 下载 GitHub Release 的全部资产（sh / ps1 / cmd）
├── tests/                    # 五层冒烟测试（详见 tests/README.md）
└── .github/                  # Issue/PR 模板、CI 工作流、自动标签
```

## 构建 ISO

### 准备工作

- 一台以 **root** 身份运行的 Linux 主机（需要 `chroot` 和挂载操作）。
- 以下命令：`xorriso`、`unsquashfs`、`mksquashfs`、`rsync`、`dd`、`awk`（在 Ubuntu/Kubuntu 上：`sudo apt-get install xorriso squashfs-tools rsync`）。
- Kubuntu 26.04.1 桌面基础 ISO，需带分层 squashfs 和 `casper/install-sources.yaml` 文件。
- 至少 **25 GB** 可用磁盘空间（峰值占用约 23 GB）。

### 快速构建

```bash
# 1. 只读预检：root、命令、基础 ISO、空间、输入文件、版本一致性
sudo ./build.sh --check

# 2. 构建 ISO
sudo BASE_ISO=/path/to/kubuntu-26.04.1-desktop-amd64.iso ./build.sh
```

成功后会在 `out/` 下生成 ISO 及其 `.md5` 文件；沿用原脚本的命名，仍为 `zhenTo-<VERSION>-amd64.iso` 和 `zhenTo-<VERSION>-amd64.md5`。除非设置 `KEEP_WORK=1`，否则 `work/` 下的中间文件会被清除。

> **注意：** `BASE_ISO` 默认值指向维护者本机的 Ubuntu ISO 路径（继承自 ZhenTo）。请务必通过 `BASE_ISO=...` 传入你自己的 Kubuntu ISO，或修改 `build.sh` 中的默认值。

### 构建模式

| 命令 | 说明 |
|---|---|
| `sudo ./build.sh` | 完整构建：解压 ISO → 添加 PPA → 在 `chroot` 中安装应用 → 品牌重塑 → 重新打包 → 验证 |
| `sudo ./build.sh --check` | 只读预检。在进行任何 apt/PPA 或文件系统更改之前退出 |
| `sudo ./build.sh --apps-only` | 仅运行 `install-app/*.sh` —— 适用于 `chroot` 内或正在运行的系统 |

### 环境变量

| 变量 | 默认值 | 用途 |
|---|---|---|
| `BASE_ISO` | `/home/oliver/iso/ubuntu-26.04.1-desktop-amd64.iso` | 源 Kubuntu 桌面 ISO（继承的默认值；请覆盖） |
| `VERSION` | `0.1.0` | 产品版本（写入 ISO 名称和 `os-release`） |
| `VOLID` | `ZhenTo <VERSION> amd64` | ISO 卷标（继承值；可覆盖为 `VOLID="Kzhento <VERSION> amd64"`，截断为 32 个字符） |
| `WORK_DIR` | `<repo>/work` | 中间构建目录 |
| `OUT_DIR` | `<repo>/out` | ISO 输出目录 |
| `PATCH_LAYERS` | `auto` | `auto` 或以空格分隔的待修改 casper 层文件列表 |
| `KEEP_WORK` | `0` | 设为 `1` 以保留中间文件用于调试 |
| `SQUASHFS_COMP` | 继承原值 | Squashfs 压缩算法（`zstd` 比 `xz` 快得多） |
| `SQUASHFS_BLOCK` | 继承原值 | Squashfs 块大小（通常为 `131072`） |

如果 `VERSION` 与 `edit-os-release/os-release` 中的版本不一致，构建脚本将拒绝运行，从而确保品牌信息不会与版本号脱节。

### 默认 Shell

镜像上的每个账户都使用 **zsh**，Starship 提示符由 `~/.zshrc` 初始化：

- `edit-terminal/edit-terminal.sh` 在 `chroot` 内运行并重写 `/etc/passwd`：`root` 与所有普通账户（uid ≥ 1000）的登录 shell 改为 `/bin/zsh`。系统账户以及已固定为 `nologin`/`false` 的账户保持不变。
- 同一脚本把 `edit-etc-default-useradd/.zshrc` 安装到 `/etc/skel/.zshrc` 以及每个已存在的家目录。原有 `.zshrc` 会保留为 `.zshrc.bak.<时间戳>`，新装文件的 uid/gid 归属于对应账户。
- `edit-etc-default-useradd/edit-etc-default-useradd.sh` 以 `SHELL=/bin/zsh` 整体覆盖 `/etc/default/useradd`（不做合并），因此安装器、`useradd` 或 `adduser` 之后新建的账户也默认使用 zsh。

两个脚本也可对真实系统或已解包的根目录运行：`sudo ./edit-terminal/edit-terminal.sh [<root>]` 与 `sudo ./edit-etc-default-useradd/edit-etc-default-useradd.sh [<target>]`。两者都不会被包含进最终镜像。

## 使用 ISO

1. **写入 U 盘**（请将 `/dev/sdX` 替换为你的实际设备——此操作会清空该设备）：

   ```bash
   sudo dd if=zhenTo-<VERSION>-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```

2. **启动**目标机器并进入 UEFI 模式，选择 U 盘。不支持传统 BIOS 启动。
3. 选择 **Try or Install KzhenTo**（若遇到显卡驱动问题则选择 **KzhenTo (safe graphics)**）——GRUB 菜单项继承自 ZhenTo——然后运行桌面安装器。

## 下载发行版

GitHub Release 的资产被拆分为 1800 MB 的压缩分卷，以低于每个文件 2 GB 的限制。按如下方式合并并校验（沿用原有文件命名）：

```bash
unzip zhenTo-<VERSION>-amd64.iso.zip
sha256sum -c zhenTo-<VERSION>-amd64.iso.sha256
```

仓库提供了辅助脚本，可通过 GitHub CLI 下载某个发行版的**全部**资产（包括草稿）：

```bash
# 需要：gh auth login（下载草稿需要写权限）
./scripts/download-release.sh v0.1.0
./scripts/download-release.sh v0.1.0 zitzhen/Kzhento ./out   # 显式指定仓库和输出目录
```

Windows 用户可使用 `scripts\download-release.ps1`（PowerShell）或 `scripts\download-release.cmd`。

## 测试

五层检查按成本从低到高排列。较低层是 PR 的强制门禁，较高层在构建/发布期间作为补充验收。

| 层级 | 命令 | 依赖 | 阻断 PR |
|---|---|---|---|
| 单元测试 / 版本一致性 | `node --test tests/*.test.js` 和 `bash tests/check-version-consistency.sh` | Node.js 22+；无需 root、无需网络 | 是 |
| 预检（mock） | `bash tests/preflight.test.sh` | bash；无需 root、无需网络 | 是 |
| 登录终端 | `bash tests/terminal.test.sh` | bash；无需 root、无需网络 | 是 |
| 产物验证 | `bash tests/verify-artifact.sh <iso> <version>` | `xorriso`、`unsquashfs`、`md5sum`、`sha256sum` | 否（在 build job 内阻断构建） |
| VM 启动冒烟 | `bash tests/vm-smoke.sh <iso> [超时秒数]` | `qemu-system-x86_64`、OVMF | 否（仅供参考） |

一次性运行本地门禁检查：

```bash
node --test tests/*.test.js
bash tests/check-version-consistency.sh
bash tests/preflight.test.sh
bash tests/terminal.test.sh
```

详情与安全注意事项见 [tests/README.md](tests/README.md)。

## 持续集成

| 工作流 | 触发条件 | 用途 |
|---|---|---|
| `pr-check.yml` | 每次 Pull Request | 语法检查、单元测试、版本一致性、shellcheck、actionlint、gitleaks、非 root 预检 |
| `dco.yml` | push 和 PR | 强制 `Signed-off-by` 签署（开发者来源认证 DCO） |
| `build-iso.yml` | `v*` tag 或手动触发 | 预检 → 构建 → 验证 → 拆分 → 发布草稿 |
| `vm-smoke.yml` | `v*` tag 或手动触发 | 参考性 QEMU + OVMF 启动检查（`continue-on-error`） |
| `auto-label.yml` | PR 活动 | 自动添加标签 |

## 参与贡献

详细流程见[贡献指南](CONTRIBUTING_zh-cn.md)（Issue 规范、DCO 签署、版本一致性、测试与 PR 检查清单）。

1. Fork https://github.com/zitzhen/Kzhento，从 `main` 创建分支。
2. 进行改动，并保持版本在 `build.sh`、`edit-os-release/os-release` 和 `.github/workflows/build-iso.yml` 三处一致。
3. 运行上述本地检查。
4. 提交时带上 DCO 签署：

   ```bash
   git commit -s -m "feat: describe your change"
   ```

   签署邮箱必须与提交作者/提交者邮箱一致，且不得使用 GitHub 的 `noreply` 地址。
5. 发起 Pull Request。选择[英文](.github/PULL_REQUEST_TEMPLATE/english.md)或[中文](.github/PULL_REQUEST_TEMPLATE/chinese.md)模板，并确保所有必需检查通过。

欢迎通过 `.github/ISSUE_TEMPLATE/` 中的模板提交 Bug 报告和功能建议。

## 许可证与致谢

本项目采用 **GNU Affero General Public License v3.0 only** 许可证 —— 详见 [LICENSE](LICENSE)。

由 **ZIT 小圳工作室** 创建。Kzhento 源自 [ZhenTo](https://github.com/zitzhen/zhenTo)；本仓库的代码复制自该项目，且未做任何修改。

- 作者 / 维护者： Oliver Lin <oliver@liuxiaozhen.dev>
- 贡献者：见 [CONTRIBUTORS](CONTRIBUTORS)
- 上游主页：https://zitzhen.cn/
- 项目主页：https://github.com/zitzhen/Kzhento
