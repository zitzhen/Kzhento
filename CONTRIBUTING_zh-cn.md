# 贡献指南

[English](CONTRIBUTING.md) · [简体中文](CONTRIBUTING_zh-cn.md)

感谢你愿意改进 Kzhento！本项目是一个基于 Kubuntu 26.04.1 的 **仅 UEFI** 桌面发行版，整个镜像由 shell 脚本组装。本指南说明从报告问题到提交 Pull Request 的完整流程。

---

## 目录

- [开始之前](#开始之前)
- [报告问题与提出建议](#报告问题与提出建议)
- [开发环境准备](#开发环境准备)
- [分支与提交规范](#分支与提交规范)
- [版本一致性（重要）](#版本一致性重要)
- [测试与检查](#测试与检查)
- [构建 ISO](#构建-iso)
- [发起 Pull Request](#发起-pull-request)
- [安全与隐私](#安全与隐私)
- [代码与文档风格](#代码与文档风格)
- [许可证](#许可证)

---

## 开始之前

- 本项目采用 [AGPL-3.0-only](LICENSE) 许可证。提交贡献即表示你同意自己的改动以该许可证发布。
- 当前脚本代码复制自 [ZhenTo](https://github.com/zitzhen/zhenTo) 且尚未修改；默认值与品牌字符串仍沿用 ZhenTo/Ubuntu。改动时请留意这一继承状态，避免把历史遗留值误认为预期行为。
- 请保持友善、建设性的沟通。讨论针对代码而非个人。

## 报告问题与提出建议

通过 [Issues](https://github.com/zitzhen/Kzhento/issues) 提交，选用 `.github/ISSUE_TEMPLATE/` 中合适的模板（中文 `bug_report.yml` / `feature_request.yml` / `maintenance.yml`，英文 `*_en.yml`）。

一份好的 Bug 报告应包含：

- 复现步骤、期望行为与实际行为；
- 宿主机系统、使用的**基础 ISO 版本**、`VERSION`、`VOLID` 等关键环境变量；
- 相关日志（例如 `build.sh` 输出、`sudo ./build.sh --check` 结果）；
- 涉及构建失败时，附上磁盘空间与 `KEEP_WORK=1` 保留的中间目录信息。

功能建议请说明使用场景与受益人群，而不仅仅是实现方案。

> 不要在 Issue/PR 中粘贴密钥、token 或个人隐私信息。

## 开发环境准备

| 需求 | 说明 |
|---|---|
| Linux 主机 | 构建需要 root 权限（`chroot` / `mount`）；建议在无其他重要服务的隔离环境中进行 |
| 基础 ISO | Kubuntu 26.04.1 Desktop amd64，通过 `BASE_ISO` 传入；镜像需带分层 squashfs 和 `casper/install-sources.yaml` |
| 磁盘空间 | 至少 25 GB 可用（峰值约 23 GB） |
| 构建依赖 | `xorriso`、`squashfs-tools`（`unsquashfs`/`mksquashfs`）、`rsync`、`dd`、`awk` |
| 测试依赖 | Node.js 22+、bash；可选 `shellcheck`、`shfmt`、`actionlint` |

克隆并（可选）启用自动 DCO 签署钩子：

```bash
git clone https://github.com/<你的用户名>/Kzhento.git
cd Kzhento
git config core.hooksPath .githooks   # 提交时自动添加 Signed-off-by
```

## 分支与提交规范

1. Fork 本仓库，从 `main` 创建分支。建议分支名体现意图，如 `feat/patchsplit`、`fix/grub-timeout`、`docs/contributing`。
2. 一个 Pull Request 只做一件事，保持改动聚焦、易于审阅。
3. **提交信息使用 conventional commit 格式**（同时用于 PR 标题和自动打标）：

   ```text
   feat(install-app): 新增 zsh 预装
   fix(boot): 修复 GRUB 启动超时
   docs: 补充贡献指南
   ci: 调整 smoke test
   build: 修正 ISO 构建参数
   ```

   可识别的类型：`feat`、`fix`、`docs`、`ci`、`build`、`refactor`、`perf`、`i18n`、`chore`、`deps`、`revert`；也支持中文前缀：`预装`、`新增`、`添加`、`增加`、`修复`、`重构`、`文档`、`说明`、`性能`。

4. **所有提交必须带 DCO 签署**（`Signed-off-by`）。CI 会拒绝未签署、邮箱不匹配或使用隐私邮箱的提交。

   ```bash
   git config user.name "Your Name"
   git config user.email "you@example.com"   # 必须是真实邮箱，不能使用 GitHub noreply 地址
   git commit -s -m "feat(install-app): 新增 zsh 预装"
   ```

   签署邮箱必须与提交的 author 或 committer 邮箱一致。`*noreply*` 地址会被拒绝。若已提交但漏签：

   ```bash
   git commit --amend -s --no-edit                              # 仅最近一次提交
   git rebase --exec "git commit --amend -s --no-edit" <base>   # 多个提交
   git push --force-with-lease                                  # 更新已推送的分支
   ```

   也可启用上文提到的 `.githooks/commit-msg` 钩子，让每次提交自动添加签署行。

## 版本一致性（重要）

产品版本必须在以下三处保持一致，当前为 `0.1.0`：

| 位置 | 字段 |
|---|---|
| `build.sh` | `VERSION` |
| `edit-os-release/os-release` | `VERSION_ID` |
| `.github/workflows/build-iso.yml` | `inputs.version.default` |

`tests/check-version-consistency.sh` 会校验这些值。修改版本号时请同时更新三处，并核对 ISO 与 MD5 产物命名（`zhenTo-<VERSION>-amd64.iso` / `.md5`）。若 `VERSION` 与 `os-release` 的 `VERSION_ID` 不一致，`build.sh` 会直接拒绝运行。

## 测试与检查

按成本从低到高排列。标为「必须」的项目是 PR 门禁，请在提交前本地跑一遍。

| 检查 | 命令 | 必须 | 说明 |
|---|---|---|---|
| 单元测试 | `node --test tests/*.test.js` | 是 | Node.js 22+，无需 root / 网络 |
| 版本一致性 | `bash tests/check-version-consistency.sh` | 是 | 校验三处版本号 |
| 预检（mock） | `bash tests/preflight.test.sh` | 是 | 用 fake bin 拦截危险命令，无需 root / 网络 |
| Shell 语法 | `bash -n` / `sh -n <file>` | 是 | 按首行解释器选择 |
| Shell 静态检查 | `shellcheck --severity=warning <files>` | 改动 `.sh` 时 | CI 对所有 `.sh` 执行 |
| Shell 格式 | `shfmt -d -i 4 <files>` | 改动 `.sh` 时 | CI 仅检查本次改动的脚本 |
| Workflow 检查 | `actionlint` | 改动 workflow 时 | 校验 `.github/workflows/` |
| 产物验证 | `bash tests/verify-artifact.sh <iso> <version>` | 构建后 | 在 build job 内阻断构建 |
| VM 启动冒烟 | `bash tests/vm-smoke.sh <iso> [超时秒数]` | 否 | QEMU + OVMF，仅供参考（`continue-on-error`） |

一次性运行本地门禁：

```bash
node --test tests/*.test.js
bash tests/check-version-consistency.sh
bash tests/preflight.test.sh
```

更多细节与安全约定见 [tests/README.md](tests/README.md)。

## 构建 ISO

本地完整构建是可选的高成本验证步骤：

```bash
sudo ./build.sh --check
sudo BASE_ISO=/path/to/kubuntu-26.04.1-desktop-amd64.iso ./build.sh
```

- 产物位于 `out/`，中间文件在 `work/`（设置 `KEEP_WORK=1` 可保留用于调试）。
- 两者都已被 `.gitignore` 忽略，**不要**把 ISO、分卷、校验文件或构建目录提交进仓库。
- 涉及构建逻辑的改动，请在 PR 中说明实际构建/验证结果。

## 发起 Pull Request

1. 将分支推送到你的 Fork，向 `main` 发起 Pull Request。
2. 选用 PR 模板：默认[中文模板](.github/PULL_REQUEST_TEMPLATE/chinese.md)，或在 compare URL 后加 `?quick_pull=1&template=english.md` 使用[英文模板](.github/PULL_REQUEST_TEMPLATE/english.md)。
3. 标题使用 conventional commit 格式，填写变更类型、关联 Issue、影响范围与测试方式。
4. 确认所有必需检查通过：`pr-check`（lint / preflight / secrets）、`dco`。CI 会在 PR 中重新执行本地检查。
5. 首次贡献者如无写权限，维护者会在 CI 通过后合入；请及时回应 Review 意见。

## 安全与隐私

- **绝不要无参数运行** `edit-grub/replace-grub.sh`（会覆盖 `/boot/grub/grub.cfg`）或 `edit-os-release/edit.sh`（会无备份覆盖 `/etc/os-release`）。测试时只走非 root 的快速失败路径，或显式传入临时目标文件。
- `build.sh` 会执行 `mount` / `chroot`、`apt` 与 PPA 操作，请仅在隔离环境中以 root 运行；`--check` 是只读预检，可安全先行。
- 新增测试时，写操作应限定在 `mktemp -d` 目录并用 `trap` 清理；危险命令必须 mock 或显式传入临时路径。
- 不要提交任何密钥、凭据或 token（`gitleaks` 会扫描）。

## 代码与文档风格

- Shell 脚本统一 `set -euo pipefail`，使用 4 空格缩进（`shfmt -i 4`），行尾统一 LF（见 `.gitattributes`）。
- 纯 JS 规则测试放在 `tests/*.test.js`，shell 冒烟脚本放在 `tests/`。
- 用户可见文档尽量保持中英文同步：README、Issue 模板与 PR 模板均已提供中英版本。

## 许可证

本项目以 **GNU Affero General Public License v3.0 only** 发布。提交 Pull Request 即表示你同意自己的贡献在相同许可证下发布。作者与维护者信息见 [README_zh-cn.md](README_zh-cn.md#许可证与致谢)，贡献者名单见 [CONTRIBUTORS](CONTRIBUTORS)。
