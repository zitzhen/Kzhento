# Kzhento

> A Kubuntu-based operating system crafted by ZIT Studio (ZIT 小圳工作室), derived from [ZhenTo](https://github.com/zitzhen/zhenTo).

[English](README.md) · [简体中文](README_zh-cn.md) · [繁體中文](README_zh-tw.md)

Kzhento is a customized Linux distribution based on **Kubuntu 26.04.1 LTS "Resolute Raccoon"**. This repository was copied from ZhenTo: its shell scripts rebrand the base desktop image, install a small set of developer tools out of the box, and produce an **UEFI-only** live/install ISO that can be written straight to a USB drive.

The whole image is assembled by shell scripts — the old dependency on Cubic has been removed. Everything from unpacking the official ISO and patching it inside a `chroot`, to repacking a bootable image, is reproducible from this repository.

> **Note on the inherited code:** the scripts themselves have not been modified. Defaults and runtime strings inside them (`BASE_ISO`, volume label, output filename, `/etc/os-release`, GRUB menu) still refer to ZhenTo/Ubuntu. Pass your own Kubuntu ISO through `BASE_ISO` when building.

| | |
|---|---|
| **Current version** | 0.1.1 |
| **Base image** | Kubuntu 26.04.1 Desktop (amd64) |
| **Firmware** | UEFI only (legacy BIOS is not supported) |
| **License** | [AGPL-3.0-only](LICENSE) |
| **Homepage** | https://github.com/zitzhen/Kzhento |
| **Issues** | https://github.com/zitzhen/Kzhento/issues |

---

## Table of Contents

- [Features](#features)
- [Repository Layout](#repository-layout)
- [Building the ISO](#building-the-iso)
  - [Prerequisites](#prerequisites)
  - [Quick Build](#quick-build)
  - [Build Modes](#build-modes)
  - [Environment Variables](#environment-variables)
- [Using the ISO](#using-the-iso)
- [Downloading a Release](#downloading-a-release)
- [Testing](#testing)
- [Continuous Integration](#continuous-integration)
- [Contributing](#contributing)
- [License & Credits](#license--credits)

---

## Features

- **Rebranded identity** — `/etc/os-release` and the GRUB boot menu are the branding points for Kzhento (currently still populated with the inherited ZhenTo strings).
- **UEFI-only image** — a single EFI system partition is appended to the ISO; boot entries are generated with `xorriso`.
- **Developer tools preinstalled** — `curl`, `git`, `zsh`, and [patchsplit](https://github.com/zitzhen/patchsplit) (from the `ppa:zitzhen/patchsplit` PPA).
- **Kzhento Desktop Installer** — the `ubuntu-desktop-bootstrap` snap from [zhento-desktop-install](https://github.com/zitzhen/zhento-desktop-install) is seeded into the image. On a live system it is installed directly; inside the `chroot` a one-shot systemd unit finishes the installation on first boot.
- **Layer-aware patching** — only the base squashfs layer of the default install source is modified. Language and enhanced-secureboot overlay layers are left untouched.
- **Checksums and verification** — `md5sum.txt` is regenerated, and CI publishes MD5 and SHA256 files for every release.
- **Automated CI** — pull requests are gated by lint/unit tests; tagged builds produce a draft GitHub Release with split, under-2 GB archives.

## Repository Layout

```text
.
├── build.sh                  # Main ISO build script (unpack → chroot → repack)
├── edit-grub/
│   ├── grub.cfg              # GRUB menu (Kzhento branding; inherited ZhenTo entries)
│   └── replace-grub.sh       # Install the menu into a target grub.cfg (with backup)
├── edit-os-release/
│   ├── os-release            # /etc/os-release branding (Kzhento; inherited values)
│   └── edit.sh               # Install the file into /etc/os-release
├── install-app/
│   ├── ppa.list              # Extra PPAs to enable during the build
│   ├── curl.sh, git.sh, zsh.sh, patchsplit.sh
│   └── Installer.sh          # Desktop Installer (snap) setup
├── scripts/
│   └── download-release.*    # Download all assets of a GitHub release (sh / ps1 / cmd)
├── tests/                    # Four-layer smoke tests (see tests/README.md)
└── .github/                  # Issue/PR templates, CI workflows, auto-labeling
```

## Building the ISO

### Prerequisites

- A Linux host running as **root** (`chroot` and mounts are required).
- The following commands: `xorriso`, `unsquashfs`, `mksquashfs`, `rsync`, `dd`, `awk` (on Ubuntu/Kubuntu: `sudo apt-get install xorriso squashfs-tools rsync`).
- The Kubuntu 26.04.1 desktop base ISO, with layered squashfs and a `casper/install-sources.yaml` file.
- At least **25 GB** of free disk space (peak usage is roughly 23 GB).

### Quick Build

```bash
# 1. Read-only preflight: root, commands, base ISO, space, inputs, version consistency
sudo ./build.sh --check

# 2. Build the ISO
sudo BASE_ISO=/path/to/kubuntu-26.04.1-desktop-amd64.iso ./build.sh
```

On success the ISO and its `.md5` file are produced under `out/`; the inherited script still names them `zhenTo-<VERSION>-amd64.iso` and `zhenTo-<VERSION>-amd64.md5`. Intermediate files under `work/` are removed unless `KEEP_WORK=1` is set.

> **Note:** the default `BASE_ISO` points to the maintainer's local Ubuntu ISO path (inherited from ZhenTo). Always pass your own Kubuntu ISO via `BASE_ISO=...` or edit the default in `build.sh`.

### Build Modes

| Command | Description |
|---|---|
| `sudo ./build.sh` | Full build: unpack ISO → add PPAs → install apps in `chroot` → rebrand → repack → verify |
| `sudo ./build.sh --check` | Read-only preflight. Exits before any apt/PPA or filesystem changes |
| `sudo ./build.sh --apps-only` | Run only `install-app/*.sh` — useful inside a `chroot` or on a running system |

### Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `BASE_ISO` | `/home/oliver/iso/ubuntu-26.04.1-desktop-amd64.iso` | Source Kubuntu desktop ISO (inherited default; override it) |
| `VERSION` | `0.1.1` | Product version (embedded in the ISO name and `os-release`) |
| `VOLID` | `ZhenTo <VERSION> amd64` | ISO volume label (inherited; override with `VOLID="Kzhento <VERSION> amd64"`, truncated to 32 characters) |
| `WORK_DIR` | `<repo>/work` | Intermediate build directory |
| `OUT_DIR` | `<repo>/out` | Output directory for the ISO |
| `PATCH_LAYERS` | `auto` | `auto` or a space-separated list of casper layer files to patch |
| `KEEP_WORK` | `0` | Set to `1` to keep intermediate files for debugging |
| `SQUASHFS_COMP` | inherited | Squashfs compression (`zstd` is much faster than `xz`) |
| `SQUASHFS_BLOCK` | inherited | Squashfs block size (usually `131072`) |

The build script refuses to run if `VERSION` does not match `edit-os-release/os-release`, so branding never drifts from the release number.

## Using the ISO

1. **Write to a USB drive** (replace `/dev/sdX` with your actual device — this erases it):

   ```bash
   sudo dd if=zhenTo-<VERSION>-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```

2. **Boot** the target machine in UEFI mode and select the USB drive. Legacy BIOS boot is not supported.
3. Choose **Try or Install ZhenTo** (or **ZhenTo (safe graphics)** if you hit display driver issues) — the GRUB labels are inherited from ZhenTo — then run the desktop installer.

## Downloading a Release

GitHub Release assets are split into 1800 MB compressed volumes to stay below the 2 GB per-file limit. Reassemble and verify them like this (the inherited file naming is retained):

```bash
unzip zhenTo-<VERSION>-amd64.iso.zip
sha256sum -c zhenTo-<VERSION>-amd64.iso.sha256
```

Helper scripts are provided to download **all** assets of a release (including drafts) with the GitHub CLI:

```bash
# Requires: gh auth login (write access is needed for drafts)
./scripts/download-release.sh v0.1.1
./scripts/download-release.sh v0.1.1 zitzhen/Kzhento ./out   # explicit repo and output dir
```

Windows users can use `scripts\download-release.ps1` (PowerShell) or `scripts\download-release.cmd`.

## Testing

Four layers of checks are arranged by increasing cost. The lower layers are mandatory PR gates; higher layers run during build/release.

| Layer | Command | Requires | Blocks PR |
|---|---|---|---|
| Unit tests / version consistency | `node --test tests/*.test.js` and `bash tests/check-version-consistency.sh` | Node.js 22+; no root, no network | Yes |
| Preflight (mocked) | `bash tests/preflight.test.sh` | bash; no root, no network | Yes |
| Artifact verification | `bash tests/verify-artifact.sh <iso> <version>` | `xorriso`, `unsquashfs`, `md5sum`, `sha256sum` | No (blocks the build job) |
| VM boot smoke | `bash tests/vm-smoke.sh <iso> [timeout]` | `qemu-system-x86_64`, OVMF | No (advisory) |

Run the local gates in one shot:

```bash
node --test tests/*.test.js
bash tests/check-version-consistency.sh
bash tests/preflight.test.sh
```

See [tests/README.md](tests/README.md) for details and safety notes.

## Continuous Integration

| Workflow | Trigger | Purpose |
|---|---|---|
| `pr-check.yml` | Every pull request | Syntax checks, unit tests, version consistency, shellcheck, actionlint, gitleaks, non-root preflight |
| `dco.yml` | Pushes and PRs | Enforces `Signed-off-by` trailers (Developer Certificate of Origin) |
| `build-iso.yml` | `v*` tag or manual dispatch | Preflight → build → verify → split → publish a draft release |
| `vm-smoke.yml` | `v*` tag or manual dispatch | Advisory QEMU + OVMF boot check (`continue-on-error`) |
| `auto-label.yml` | PR activity | Automatic labeling |

## Contributing

1. Fork https://github.com/zitzhen/Kzhento and create a branch from `main`.
2. Make your change, keeping the version consistent across `build.sh`, `edit-os-release/os-release`, and `.github/workflows/build-iso.yml`.
3. Run the local checks above.
4. Commit with a DCO sign-off:

   ```bash
   git commit -s -m "feat: describe your change"
   ```

   The sign-off email must match your commit author/committer email and must not be a GitHub `noreply` address.
5. Open a pull request. Choose the [English](.github/PULL_REQUEST_TEMPLATE/english.md) or [Chinese](.github/PULL_REQUEST_TEMPLATE/chinese.md) template, and make sure all required checks pass.

Bug reports and feature requests are welcome via the issue templates in `.github/ISSUE_TEMPLATE/`.

## License & Credits

Licensed under the **GNU Affero General Public License v3.0 only** — see [LICENSE](LICENSE).

Created by **ZIT Studio (ZIT 小圳工作室)**. Kzhento is derived from [ZhenTo](https://github.com/zitzhen/zhenTo); the code in this repository was copied from that project and has not been modified.

- Author / maintainer: Oliver Lin <oliver@liuxiaozhen.dev>
- Contributors: see [CONTRIBUTORS](CONTRIBUTORS)
- Upstream homepage: https://zitzhen.cn/
- Project homepage: https://github.com/zitzhen/Kzhento
