# 冒烟测试工作流

各层检查按成本递增排列，低层是 PR 必过门禁，高层是构建/发布期的补充验收。

| 层 | 文件 | 运行方式 | 前置条件 | 是否阻断 PR |
|---|---|---|---|---|
| PR 快检 / 单测 | `auto-label.test.js`、`workflow-split.test.js`、`check-version-consistency.sh` | `node --test tests/*.test.js`、`bash tests/check-version-consistency.sh` | Node.js 22+；无 root、无网络 | 是 |
| 构建前预检 | `preflight.test.sh` | `bash tests/preflight.test.sh` | bash；无 root、无网络（外部命令用 fake bin mock） | 是 |
| 工作流版本解析 | `resolve-meta.test.sh` | `bash tests/resolve-meta.test.sh` | bash；无 root、无网络（纯环境变量输入） | 是 |
| 下载重试 | `zhento-fetch.test.sh` | `bash tests/zhento-fetch.test.sh` | bash；无 root、无网络（curl 被桩替换） | 是 |
| 登录终端 | `terminal.test.sh` | `bash tests/terminal.test.sh` | bash、python3；无 root、无网络（`id` 被 mock，目标均为临时目录） | 是 |
| 素材渲染 | `render.test.sh` | `bash tests/render.test.sh` | bash、Python 3 + Pillow、`logo/kzhento_transparent.png`（缺失则跳过）；无 root、无网络 | 是 |
| 发行版图标安装 | `edit-icons.test.sh` | `bash tests/edit-icons.test.sh` | bash、Python 3 + Pillow、`logo/kzhento_transparent.png`（缺失则跳过）；无 root、无网络（`id` 被 mock，目标均为临时目录） | 是 |
| 欢迎中心首页 | `edit-welcome.test.sh` | `bash tests/edit-welcome.test.sh` | bash、Python 3 + Pillow、`logo/kzhento_transparent.png`（缺失则跳过）、`qmllint`（缺失则跳过该项）；无 root、无网络 | 是 |
| 默认壁纸与移除壁纸 | `edit-wallpaper.test.sh` | `bash tests/edit-wallpaper.test.sh` | bash；无 root、无网络（`id` 被 mock，目标均为临时目录） | 是 |
| 开机画面载荷 | `plymouth-payload.test.sh` | `bash tests/plymouth-payload.test.sh` | bash；无 root、无网络、无需 logo | 是 |
| casper 引导文件同步 | `casper-boot-sync.test.sh` | `bash tests/casper-boot-sync.test.sh` | bash；无 root、无网络 | 是 |
| 发布镜像核查器 | `release-iso-probe.test.sh` | `bash tests/release-iso-probe.test.sh` | bash、`mksquashfs`、`cpio`、`gzip`；无 root、无网络 | 是 |
| 构建后产物验收 | `verify-artifact.sh` | `bash tests/verify-artifact.sh <iso> <version>` | `xorriso`、`unsquashfs`、`md5sum`、`sha256sum` | 否（在 build job 内阻断构建） |
| 发布镜像核查 | `release-iso-probe.sh` | `bash tests/release-iso-probe.sh <iso>` | `xorriso`、`unsquashfs`、`unmkinitramfs` 或 `zstd` + `cpio`；需约 6G 临时空间；无 root | 否（离线、发布前自查） |
| VM 启动冒烟 | `vm-smoke.sh` | `bash tests/vm-smoke.sh <iso> [超时秒数]` | `qemu-system-x86_64`、OVMF | 否（advisory） |

## 本地一键跑

```bash
node --test tests/*.test.js
bash tests/check-version-consistency.sh
bash tests/preflight.test.sh
bash tests/resolve-meta.test.sh
bash tests/zhento-fetch.test.sh
bash tests/terminal.test.sh
bash tests/plymouth-payload.test.sh
bash tests/casper-boot-sync.test.sh
bash tests/release-iso-probe.test.sh
bash tests/render.test.sh
bash tests/edit-icons.test.sh
bash tests/edit-welcome.test.sh
bash tests/edit-wallpaper.test.sh
```

## 版本真值

产品版本统一为 `0.1.0`（`build.sh`、`edit-os-release/os-release` 的 `VERSION_ID`、`.github/workflows/build-iso.yml` 的 `inputs.version default`）。基础镜像为 **Kubuntu 26.04.1**（代码复制自 ZhenTo，脚本默认值与相关字符串尚未同步修改），`os-release` 的 `VERSION` 文案为 `26.04.1 (Resolute Raccoon)`。`check-version-consistency.sh` 负责防止这三处再次漂移。

## 安全约定

- `preflight.test.sh` 用临时 fake bin 拦截 `apt-get`、`add-apt-repository`、`curl`、`snap`、`gh`，并 mock `id`/`df`/`cp`；不会真的装包、联网或改系统。
- 绝不要无参数运行 `edit-grub/replace-grub.sh`（会覆盖 `/boot/grub/grub.cfg`）或 `edit-os-release/edit.sh`（会无备份覆盖 `/etc/os-release`）。测试里只走非 root 快速失败路径，或给 `replace-grub.sh` 显式传临时目标文件。
- `edit-terminal/edit-terminal.sh` 无参数运行会改写真实 `/etc/passwd`，所以 `terminal.test.sh` 始终传一个伪造的根目录（内含 `bin/zsh` 与 `etc/passwd`），从不触碰宿主机。改动 `edit-terminal.sh` 的写入步骤或诊断文案时，测试会用 `python3` 生成一份副本并替换掉对应语句，用来验证“写入没落地就不会报成功”，因此该测试需要 `python3`。`edit-etc-default-useradd/edit-etc-default-useradd.sh` 则只对临时目标路径运行。
- `render.test.sh` 只读 `LOGO_DIR`（默认 `logo/`）里的缓存图，输出全部写进 `mktemp -d`；它还会断言渲染前后源图 sha256 不变，防止渲染器改写输入。logo 本身**不入库**（由 `edit-logo.sh` 构建时下载），因此干净检出里没有它，此时该测试以「跳过」退出 0；CI 会先用 `edit-logo.sh` 里锁定的同一 commit 取图并校验 sha256，再跑测试，确保渲染器确实被测到。`verify-artifact.sh` 只从 ISO 提取少量小文件，不展开 6.5G 根文件系统；ISO 自带 `md5sum.txt` 只抽查关键文件，不做全量校验。
- `edit-icons.test.sh` 用 `id` 桩模拟 root，在临时目录里搭出一棵「像原版 Kubuntu」的图标树（`places/@2x`、`@3x` 是指向普通目录的符号链接），因此测的是真实安装逻辑而不是副本。它守护四件事：每个尺寸目录都拿到 PNG 且尺寸与该目录声明的一致；原版 KDE SVG 被留为 `.zhento-orig` 后删除（只遮挡不删除时，偏好 SVG 的加载器仍会画原图）；同一真实目录只写一次、取最大尺寸（逐个名字写会让 16 px 目录最后剩下 48 px 图，已用倒序故障注入验证）；重跑不会把 `.zhento-orig` 覆盖成 Kzhento 自己的图。它不断言「中心有墨」——图形是空心圆环，中心本来就透明。
- `edit-welcome.test.sh` 覆盖欢迎中心首页：它既测仓库里的 QML 载荷（用 `qmllint` 解析，并先验证 `qmllint` 对一份故意写坏的文件确实会报错，避免「跑了个空检查」），也测安装脚本。断言里最要紧的两条是：页面**按原文件名原地替换**（plasma-welcome 枚举 `extra-pages/*.qml`，多一个文件就会在导览里多出一页），以及原版备份**不是 `.qml`**、因此不会被枚举——这一点已用故障注入验证（让脚本额外写一个 `01-Kzhento.qml` 会被判失败）。它还断言载荷不再引用 `kubuntu_tour.svg` / `kubuntu_donate.svg`、不再出现 `kubuntu.org`，以及重复运行不会把原版备份覆盖成我们自己的页面。
- `plymouth-payload.test.sh` 只读 `edit-plymouth/` 下的文本文件，不渲染、不装包：它校验主题文件（模块、`ImageDir`/`AnimationDir`、水印与动画帧名）与 `edit-plymouth.sh` 实际写出的文件一致，并断言 `default.plymouth` 在安装脚本与 `select-theme.sh` 里指向同一个主题。`render.test.sh` 只测渲染器，主题文件名与安装脚本写歪时它发现不了，这一层补的就是这个缝。
- `casper-boot-sync.test.sh` 守护 `build.sh` 把重建的 initramfs 装到 `casper/initrd` 这一步，覆盖两个只有真正启动才看得见的 bug。其一：GRUB 从 `/casper/initrd` 启动，而 `update-initramfs` 只写层内的 `/boot/initrd.img-<kver>`，漏掉拷贝时层内每一个品牌化检查都仍然通过，开机画面却还是基础镜像的原版素材。其二：chroot 里重建会丢掉 live 启动配置 `conf/uuid.conf` 与 `conf/conf.d/default-boot-to-casper.conf`（casper 的 initramfs hook 只在 `CASPER_GENERATE_UUID` 非空时才写它们），缺失后 init 回退到 `BOOT=local`，`run-init` 找不到可切换的根，PID 1 直接死掉——这就是 issue #21 的内核 panic。测试用临时目录造一份带前置微码段的假 initramfs，通过 `awk` 从 `build.sh` 里原样抽出 `sync_casper_boot()` / `unpack_initramfs()` / `repack_initramfs()` 来跑，因此测的是真实实现而不是副本；它还断言微码段在重打包后仍然存在，以及调用顺序在 `apply_plymouth_theme` 之后、`mksquashfs` 之前。
- `vm-smoke.sh` 以 QEMU + OVMF 启动 ISO（UEFI-only 镜像不能用传统 BIOS），串口日志作为主要观测手段。受限于镜像自带 GRUB 的 `quiet splash` 且未开启串口控制台，登录提示符不保证出现；这一层主要用于捕获固件/GRUB/内核级灾难性失败，失败也不会阻断发布。
- `release-iso-probe.sh` 与 `verify-artifact.sh` 的分工：后者是构建门禁，只在刚构建完、构建树还在时有意义，断言的是「本次构建产出正确」；前者面向**已发布的 ISO 文件**，把 `build.sh` 会改的每一个品牌面逐条报成「已改 / 仍是原版」，因此能发现「这个 ISO 是从早于某步品牌化的检出构建的」这类问题。它只读 ISO，不写系统、不需要 root，但要把 squashfs 与 initramfs 解到 `mktemp -d`（约 6G），因此不进 PR 门禁。`KEEP_WORK=1` 可保留解包结果便于排查。

## CI 接线

- `.github/workflows/pr-check.yml`：lint job 内增加单测（含 `workflow-split.test.js`）与版本一致性；`preflight` job 内先跑 `preflight.test.sh` 与 `resolve-meta.test.sh`，再跑 `terminal.test.sh`、`plymouth-payload.test.sh`、`casper-boot-sync.test.sh`、`release-iso-probe.test.sh`、`render.test.sh`、`edit-icons.test.sh` 与 `edit-welcome.test.sh`。
- `.github/workflows/build-iso.yml`：两个 job，`build` 与 `release`。`build` 在 `./build.sh --check` 之后跑构建，生成 sha256 并把 ISO 与校验文件作为 workflow artifact 上传（`compression-level: 0`，ISO 本身已压缩）；`release` 下载该 artifact，先跑 `verify-artifact.sh` 再拆分上传并创建草稿 Release。拆开的目的是让尾部失败（上传报错、草稿已存在、验收断言需要复核）能用「Re-run failed jobs」只重跑 `release`，耗时以分钟计而不是重跑整次构建，同时调试时 ISO 仍在 artifact 里。artifact 保留 7 天，因此发布必须在 7 天内完成或重跑。
- `.github/workflows/build-iso.yml` 的两个 job 各自调用 `scripts/resolve-meta.sh` 解析版本、tag 与 base ISO 缓存 key，**不从 `needs.*.outputs` 取值**：重跑失败的 job 时，上游已成功的 job 不会把 outputs 注入进来，取 `needs` 会拿到空版本并产出 `kzhento--amd64.iso`。`workflow-split.test.js` 断言工作流里不存在 `needs.*.outputs` 引用，`resolve-meta.test.sh` 断言相同输入（URL + sha256）在 tag 与手动触发两条路径上得到同一个缓存 key。
- `.github/workflows/vm-smoke.yml`：仅手动或 `v*` tag 触发，独立 job 且 `continue-on-error: true`。GitHub 托管 runner 无 `/dev/kvm`，TCG 软件模拟很慢；需要稳定结果时应迁到带 KVM 的自托管 runner。

## 新增测试时

纯 JS 规则继续放 `auto-label.test.js`；shell 冒烟脚本放本目录，统一 `set -euo pipefail`、写操作限定 `mktemp -d` 并 `trap` 清理，任何危险系统命令都必须 mock 或显式传临时路径。
