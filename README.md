# Kzhento

> A Kubuntu-based operating system crafted by ZIT Studio (ZIT 小圳工作室), derived from [ZhenTo](https://github.com/zitzhen/zhenTo).

[English](README.md) · [简体中文](README_zh-cn.md) · [繁體中文](README_zh-tw.md)

Kzhento is a customized Linux distribution based on **Kubuntu 26.04.1 LTS "Resolute Raccoon"**. This repository was copied from ZhenTo: its shell scripts rebrand the base desktop image, install a small set of developer tools out of the box, and produce an **UEFI-only** live/install ISO that can be written straight to a USB drive.

The whole image is assembled by shell scripts — the old dependency on Cubic has been removed. Everything from unpacking the official ISO and patching it inside a `chroot`, to repacking a bootable image, is reproducible from this repository.

> **Note on the inherited code:** the scripts themselves have not been modified. Defaults and runtime strings inside them (`BASE_ISO`, volume label, output filename, `/etc/os-release`, GRUB menu) still refer to ZhenTo/Ubuntu. Pass your own Kubuntu ISO through `BASE_ISO` when building.

| | |
|---|---|
| **Current version** | 0.1.0 |
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
- **Bundled logo** — the Kzhento logo is downloaded from [kzhento-icon](https://github.com/zitzhen/kzhento-icon) at build time (pinned commit + SHA256 check) and installed under `/usr/share/backgrounds/kzhento/`, so no binary artwork is stored in this repository.
- **UEFI-only image** — a single EFI system partition is appended to the ISO; boot entries are generated with `xorriso`.
- **Developer tools preinstalled** — `curl`, `git`, `zsh`, and [patchsplit](https://github.com/zitzhen/patchsplit) (from the `ppa:zitzhen/patchsplit` PPA).
- **zsh for every account** — existing accounts are switched to `/bin/zsh` with a Starship-enabled `.zshrc`, and `/etc/default/useradd` gives new accounts the same shell.
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
│   ├── edit.sh               # Install the file into /etc/os-release
│   ├── kcm-about-distrorc    # Kzhento "About this System" page (name, version, logo, website)
│   └── edit-about-system.sh  # Install the rc file into /etc/xdg
├── edit-terminal/
│   └── edit-terminal.sh      # Switch every existing account to zsh and install the Kzhento .zshrc
├── edit-logo.sh/
│   ├── edit-logo.sh          # Download + install Kzhento logo into the image
│   ├── edit-pixmaps.sh       # Replace /usr/share/pixmaps/ubuntu-logo-text-dark.png with the wordmark
│   └── edit-icons.sh         # Replace the start-here-kde icon (About page + launcher)
├── edit-plymouth/
│   ├── render.py             # Render the logo into boot artwork, icon master and wordmark
│   ├── plymouth/minimal.plymouth # The Kzhento boot theme (two-step module)
│   ├── edit-plymouth.sh      # Install the theme and the artwork into a target root
│   └── select-theme.sh       # Select the theme and rebuild the initramfs (needs root)
├── edit-notification/
│   ├── po/                   # Kzhento catalogues for kubuntu-notification-helper (en, zh_CN)
│   ├── plasma-welcome/       # K-Zhento's first Welcome Center page
│   ├── edit-notification.sh  # Install the catalogues and rename the launcher entry
│   └── edit-welcome.sh       # Replace plasma-welcome's first page
├── edit-etc-default-useradd/
│   ├── edit-etc-default-useradd.sh # Write SHELL=/bin/zsh into /etc/default/useradd (new accounts)
│   ├── useradd               # Kzhento /etc/default/useradd
│   └── .zshrc                # Kzhento ~/.zshrc with the Starship prompt
├── install-app/
│   ├── ppa.list              # Extra PPAs to enable during the build
│   ├── curl.sh, git.sh, zsh.sh, patchsplit.sh
│   └── Installer.sh          # Desktop Installer (snap) setup
├── scripts/
│   └── download-release.*    # Download all assets of a GitHub release (sh / ps1 / cmd)
├── tests/                    # Layered smoke tests (see tests/README.md)
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
| `VERSION` | `0.1.0` | Product version (embedded in the ISO name and `os-release`) |
| `VOLID` | `ZhenTo <VERSION> amd64` | ISO volume label (inherited; override with `VOLID="Kzhento <VERSION> amd64"`, truncated to 32 characters) |
| `WORK_DIR` | `<repo>/work` | Intermediate build directory |
| `OUT_DIR` | `<repo>/out` | Output directory for the ISO |
| `PATCH_LAYERS` | `auto` | `auto` or a space-separated list of casper layer files to patch |
| `KEEP_WORK` | `0` | Set to `1` to keep intermediate files for debugging |
| `SQUASHFS_COMP` | inherited | Squashfs compression (`zstd` is much faster than `xz`) |
| `SQUASHFS_BLOCK` | inherited | Squashfs block size (usually `131072`) |

The build script refuses to run if `VERSION` does not match `edit-os-release/os-release`, so branding never drifts from the release number.

### Default Shell

Every account on the image uses **zsh**, with the Starship prompt initialised from `~/.zshrc`:

- `edit-terminal/edit-terminal.sh` runs inside the `chroot` and rewrites `/etc/passwd`: the login shell of `root` and of every regular account (uid ≥ 1000) becomes `/bin/zsh`. System accounts and accounts already pinned to `nologin`/`false` are left alone.
- The same script installs `edit-etc-default-useradd/.zshrc` into `/etc/skel/.zshrc` and into every existing home directory. A pre-existing `.zshrc` is kept as `.zshrc.bak.<timestamp>`, and the installed copy keeps the account's uid/gid.
- `edit-etc-default-useradd/edit-etc-default-useradd.sh` overwrites `/etc/default/useradd` with `SHELL=/bin/zsh` (no merging), so accounts created later — by the installer, `useradd` or `adduser` — start with zsh too.

Both scripts also run against a real system or an unpacked root: `sudo ./edit-terminal/edit-terminal.sh [<root>]` and `sudo ./edit-etc-default-useradd/edit-etc-default-useradd.sh [<target>]`. Neither is shipped in the final image.

### Branding

Kubuntu's own artwork is replaced on six surfaces, each by a step that `build.sh` runs inside the unpacked layer:

| Surface | Controlled by | Step |
|---|---|---|
| Boot splash (Plymouth) | `/usr/share/plymouth/themes/minimal` + `default.plymouth` | `edit-plymouth/edit-plymouth.sh`, then `select-theme.sh` |
| Distro wordmark in `/usr/share/pixmaps` | `ubuntu-logo-text-dark.png` | `edit-logo.sh/edit-pixmaps.sh` |
| Distro icon (`start-here-kde`) | the icon themes' `places/*/start-here-kde.*` | `edit-logo.sh/edit-icons.sh` |
| Welcome Center notification | `kubuntu-notification-helper.mo` catalogues | `edit-notification/edit-notification.sh` |
| Welcome Center first page | `plasma-welcome/extra-pages/01-Kubuntu.qml` | `edit-notification/edit-welcome.sh` |
| "About this System" page | `/etc/xdg/kcm-about-distrorc` | `edit-os-release/edit-about-system.sh` |

The splash artwork is generated from the logo rather than shipped as a static file, so it stays in sync with the brand: `edit-plymouth/render.py` produces a white-on-transparent watermark (the full logo, at the bottom of the boot screen), a 48×48 spinner frame and a 512×512 icon master, the last two cut from the same ringed "Kz", plus a 1024×309 wordmark for the Welcome Center page. The spinner and the watermark are recoloured for the black boot screen (charcoal ink to white, blue accents kept); the icon master and the wordmark keep the logo's own colours, because they are drawn on the light desktop. `tests/render.test.sh` checks all four.

The "About this System" page does **not** take an image path: `kcm_about-distro` hands `LogoPath` to `QIcon::fromTheme()`, which only resolves icon *names*. So the logo on that page is the `start-here-kde` icon, and `edit-logo.sh/edit-icons.sh` is what puts Kzhento there. It writes a PNG into every size directory of the Breeze, Breeze Dark and hicolor themes (16 px up to 512 px, HiDPI variants included) and moves the stock KDE SVG aside as `start-here-kde.svg.zhento-orig` — the SVG is removed rather than shadowed, so a loader with a different preference cannot fall back to it. The same icon name is what Plasma uses for the application launcher, so the launcher is branded by the same step, and `tests/edit-icons.test.sh` covers it.

Details worth knowing when changing this:

- The Welcome Center window is two separate surfaces. `kubuntu-notification-helper` only supplies the *notification* that opens it, and its strings come from a gettext catalogue this repository overrides. The window's *content* is `plasma-welcome`'s `extra-pages/01-Kubuntu.qml`, where the heading, the body and both images are written into the QML itself — and upstream ships no `plasma-welcome` catalogue for the untranslated source language, so there is no msgid to override. Branding the notification alone leaves a window titled K-Zhento containing Kubuntu's tour, which is exactly what the 0.1.0 build shipped. `edit-welcome.sh` replaces that page in place and keeps the stock one as `.zhento-orig`; the replacement draws the wordmark rendered by `render.py` and drops the Donate badge rather than repointing it at a campaign that does not exist.
- The page is replaced at its **stock file name**, not added under a new one: plasma-welcome enumerates `extra-pages/*.qml`, so a second file would appear as an extra page in the tour. The `.zhento-orig` backup is deliberately not a `.qml` file, which is why it is invisible to that enumeration.
- Breeze's `places/@2x` and `@3x` directories are **symlinks to the plain one** on a stock Kubuntu, so several icon names resolve to a single directory. `edit-icons.sh` collapses them by real path and keeps the largest size asked for; writing each name in turn left a 48 px image in the directory the theme reads for 16 px icons.
- `watermark.png` in the stock `spinner` theme is a **dpkg symlink** to `/usr/share/pixmaps/ubuntu-logo-text-dark.png`. `edit-plymouth.sh` replaces it with a regular file, so the boot screen no longer depends on that pixmap, and `edit-pixmaps.sh` keeps the upstream file as `.zhento-orig`.
- The Kzhento theme uses the `two-step` module, so it draws `animation-*.png` from its own `ImageDir`; the stock `spinner` theme's `throbber-*.png` frames are that theme's script assets and are deliberately **not** copied over. `edit-plymouth.sh` installs the rendered mark as `animation-0001.png`, and `tests/plymouth-payload.test.sh` keeps the theme file and the installer in agreement.
- The machine's own boot logo stays on screen: `two-step` only paints the firmware image (`/sys/firmware/acpi/bgrt/image`) when `UseFirmwareBackground` is true, and it defaults to off. The stock Kubuntu theme sets it in `[two-step]` and in every phase section, and `minimal.plymouth` does the same — omitting the key silently dropped the OEM logo and left a plain black background. `tests/plymouth-payload.test.sh` asserts the key is set everywhere the module reads it.
- The theme only reaches the boot screen once it is baked into the **initramfs**, which is why `select-theme.sh` rebuilds it last, after the chroot is gone (it needs `/proc` and `/sys`).
- Baking the initramfs into the **layer** is not enough: GRUB boots `/casper/initrd`, which lives outside every squashfs, while `update-initramfs` only writes `/boot/initrd.img-<kver>` inside the layer. `build.sh` installs the rebuilt initramfs as `casper/initrd` (and keeps `casper/vmlinuz` in step) before repacking, and `tests/casper-boot-sync.test.sh` pins that. Without it every branding check inside the layer still passes while the ISO boots the base ISO's stock artwork — which is exactly how the branded 0.1.0 release shipped showing the Kubuntu logo.
- Copying the file out is still not enough. The live boot needs `conf/uuid.conf` and `conf/conf.d/default-boot-to-casper.conf`, and the casper initramfs hook only writes them when `CASPER_GENERATE_UUID` is set — which the stock image build does and a chroot rebuild does not. Without them init falls back to `BOOT=local`, `run-init` has no root to switch to, and PID 1 dies with `Attempted to kill init!` (issue #21). `build.sh` injects both before repacking the archive. Two shortcuts do **not** work and are documented in `build.sh`: appending a cpio segment (the kernel reads it as another archive and fails with `invalid magic at start of compressed archive`), and `cpio -id` on the whole archive (it stops at the first `TRAILER!!!` and unpacks only the leading microcode segment).

Each step is skipped with a warning, not a failure, when its inputs are absent — so an image without KDE still builds.

## Using the ISO

1. **Write to a USB drive** (replace `/dev/sdX` with your actual device — this erases it):

   ```bash
   sudo dd if=zhenTo-<VERSION>-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```

2. **Boot** the target machine in UEFI mode and select the USB drive. Legacy BIOS boot is not supported.
3. Choose **Try or Install KzhenTo** (or **KzhenTo (safe graphics)** if you hit display driver issues) — the GRUB labels are inherited from ZhenTo — then run the desktop installer.

## Downloading a Release

GitHub Release assets are split into 1800 MB compressed volumes to stay below the 2 GB per-file limit. Reassemble and verify them like this (the inherited file naming is retained):

```bash
unzip zhenTo-<VERSION>-amd64.iso.zip
sha256sum -c zhenTo-<VERSION>-amd64.iso.sha256
```

Helper scripts are provided to download **all** assets of a release (including drafts) with the GitHub CLI:

```bash
# Requires: gh auth login (write access is needed for drafts)
./scripts/download-release.sh v0.1.0
./scripts/download-release.sh v0.1.0 zitzhen/Kzhento ./out   # explicit repo and output dir
```

Windows users can use `scripts\download-release.ps1` (PowerShell) or `scripts\download-release.cmd`.

## Testing

The checks are arranged by increasing cost. The lower layers are mandatory PR gates; higher layers run during build/release.

| Layer | Command | Requires | Blocks PR |
|---|---|---|---|
| Unit tests / version consistency | `node --test tests/*.test.js` and `bash tests/check-version-consistency.sh` | Node.js 22+; no root, no network | Yes |
| Preflight (mocked) | `bash tests/preflight.test.sh` | bash; no root, no network | Yes |
| Login shell | `bash tests/terminal.test.sh` | bash; no root, no network | Yes |
| Boot splash artwork | `bash tests/render.test.sh` | bash, Python 3 + Pillow, `logo/kzhento_transparent.png` (skipped if absent); no root, no network | Yes |
| Boot splash payload | `bash tests/plymouth-payload.test.sh` | bash; no root, no network | Yes |
| Casper boot sync | `bash tests/casper-boot-sync.test.sh` | bash; no root, no network | Yes |
| Release ISO probe test | `bash tests/release-iso-probe.test.sh` | bash, `mksquashfs`, `cpio`, `gzip`; no root, no network | Yes |
| Artifact verification | `bash tests/verify-artifact.sh <iso> <version>` | `xorriso`, `unsquashfs`, `md5sum`, `sha256sum` | No (blocks the build job) |
| VM boot smoke | `bash tests/vm-smoke.sh <iso> [timeout]` | `qemu-system-x86_64`, OVMF | No (advisory) |

Run the local gates in one shot:

```bash
node --test tests/*.test.js
bash tests/check-version-consistency.sh
bash tests/preflight.test.sh
bash tests/terminal.test.sh
bash tests/plymouth-payload.test.sh
bash tests/release-iso-probe.test.sh
bash tests/render.test.sh
```

To check what an already-built or downloaded ISO actually shows, run the probe on it. It reports every branded surface as branded or stock and needs no root:

```bash
bash tests/release-iso-probe.sh /path/to/kzhento-amd64.iso
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

See the [Contributing Guide](CONTRIBUTING.md) for the full workflow (issue guidelines, DCO sign-off, version consistency, tests and PR checklist).

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
