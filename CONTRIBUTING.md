# Contributing Guide

[English](CONTRIBUTING.md) · [简体中文](CONTRIBUTING_zh-cn.md)

Thanks for your interest in improving Kzhento! This project is a **UEFI-only** desktop distribution based on Kubuntu 26.04.1, assembled entirely by shell scripts. This guide covers the workflow from reporting an issue to opening a pull request.

---

## Table of Contents

- [Before You Start](#before-you-start)
- [Reporting Issues and Requesting Features](#reporting-issues-and-requesting-features)
- [Development Setup](#development-setup)
- [Branches and Commits](#branches-and-commits)
- [Version Consistency (Important)](#version-consistency-important)
- [Tests and Checks](#tests-and-checks)
- [Building the ISO](#building-the-iso)
- [Opening a Pull Request](#opening-a-pull-request)
- [Security and Privacy](#security-and-privacy)
- [Code and Documentation Style](#code-and-documentation-style)
- [License](#license)

---

## Before You Start

- This project is licensed under [AGPL-3.0-only](LICENSE). By contributing you agree that your changes are released under the same license.
- The current scripts were copied from [ZhenTo](https://github.com/zitzhen/zhenTo) and have not been modified; defaults and branding strings still follow ZhenTo/Ubuntu. Keep this inherited state in mind so historical values are not mistaken for intended behavior.
- Please keep communication friendly and constructive. Discuss the code, not the person.

## Reporting Issues and Requesting Features

Use the [Issues](https://github.com/zitzhen/Kzhento/issues) page and pick the right template from `.github/ISSUE_TEMPLATE/` (Chinese `bug_report.yml` / `feature_request.yml` / `maintenance.yml`, English `*_en.yml`).

A useful bug report includes:

- Steps to reproduce, expected behavior and actual behavior;
- Host OS, the **base ISO version** used, and key environment variables such as `VERSION` and `VOLID`;
- Relevant logs (for example `build.sh` output or the result of `sudo ./build.sh --check`);
- For build failures, available disk space and, when possible, intermediate files kept with `KEEP_WORK=1`.

For feature requests, describe the use case and who benefits, not just the proposed implementation.

> Never paste secrets, tokens or personal information into issues or pull requests.

## Development Setup

| Requirement | Notes |
|---|---|
| Linux host | Building requires root (`chroot` / `mount`); prefer an isolated environment without other important services |
| Base ISO | Kubuntu 26.04.1 Desktop amd64, passed via `BASE_ISO`; needs layered squashfs and `casper/install-sources.yaml` |
| Disk space | At least 25 GB free (peak usage about 23 GB) |
| Build tools | `xorriso`, `squashfs-tools` (`unsquashfs`/`mksquashfs`), `rsync`, `dd`, `awk` |
| Test tools | Node.js 22+, bash; optionally `shellcheck`, `shfmt`, `actionlint` |

Clone and (optionally) enable the automatic DCO sign-off hook:

```bash
git clone https://github.com/<your-username>/Kzhento.git
cd Kzhento
git config core.hooksPath .githooks   # automatically adds Signed-off-by on commit
```

## Branches and Commits

1. Fork the repository and create a branch from `main`. Suggested names reflect intent, e.g. `feat/patchsplit`, `fix/grub-timeout`, `docs/contributing`.
2. Keep one pull request focused on one thing, so it is easy to review.
3. **Use conventional commits for commit messages** (also used for PR titles and auto-labeling):

   ```text
   feat(install-app): add zsh to preinstalled apps
   fix(boot): fix GRUB boot timeout
   docs: add contributing guide
   ci: adjust smoke test
   build: correct ISO build parameter
   ```

   Recognized types: `feat`, `fix`, `docs`, `ci`, `build`, `refactor`, `perf`, `i18n`, `chore`, `deps`, `revert`. Chinese prefixes are also supported: `预装`, `新增`, `添加`, `增加`, `修复`, `重构`, `文档`, `说明`, `性能`.

4. **Every commit must carry a DCO sign-off** (`Signed-off-by`). CI rejects commits that are unsigned, use a mismatched email, or use a privacy address.

   ```bash
   git config user.name "Your Name"
   git config user.email "you@example.com"   # a real address; no GitHub noreply addresses
   git commit -s -m "feat(install-app): add zsh to preinstalled apps"
   ```

   The sign-off email must match the commit author or committer email. `*noreply*` addresses are rejected. If you already committed without signing:

   ```bash
   git commit --amend -s --no-edit                              # latest commit only
   git rebase --exec "git commit --amend -s --no-edit" <base>   # multiple commits
   git push --force-with-lease                                  # update the pushed branch
   ```

   Alternatively, enable the `.githooks/commit-msg` hook described above to add the trailer automatically on every commit.

## Version Consistency (Important)

The product version must match in three places; currently `0.1.0`:

| Location | Field |
|---|---|
| `build.sh` | `VERSION` |
| `edit-os-release/os-release` | `VERSION_ID` |
| `.github/workflows/build-iso.yml` | `inputs.version.default` |

`tests/check-version-consistency.sh` validates these values. When bumping the version, update all three and check the output names (`kzhento-<VERSION>-amd64.iso` / `.md5`). `build.sh` refuses to run if `VERSION` does not match the `VERSION_ID` in `os-release`.

## Tests and Checks

Ordered by increasing cost. Items marked "Required" are PR gates — run them locally before submitting.

| Check | Command | Required | Notes |
|---|---|---|---|
| Unit tests | `node --test tests/*.test.js` | Yes | Node.js 22+; no root, no network |
| Version consistency | `bash tests/check-version-consistency.sh` | Yes | Validates the three version strings |
| Preflight (mocked) | `bash tests/preflight.test.sh` | Yes | Uses fake bins to intercept dangerous commands; no root, no network |
| Shell syntax | `bash -n` / `sh -n <file>` | Yes | Choose based on the shebang |
| Shell lint | `shellcheck --severity=warning <files>` | When `.sh` changes | CI runs this on all `.sh` files |
| Shell format | `shfmt -d -i 4 <files>` | When `.sh` changes | CI checks only changed scripts |
| Workflow lint | `actionlint` | When workflows change | Validates `.github/workflows/` |
| Artifact verification | `bash tests/verify-artifact.sh <iso> <version>` | After building | Blocks the build job |
| VM boot smoke | `bash tests/vm-smoke.sh <iso> [timeout]` | No | QEMU + OVMF, advisory (`continue-on-error`) |

Run the local gates in one shot:

```bash
node --test tests/*.test.js
bash tests/check-version-consistency.sh
bash tests/preflight.test.sh
```

See [tests/README.md](tests/README.md) for details and safety notes.

## Building the ISO

A full local build is an optional, higher-cost verification step:

```bash
sudo ./build.sh --check
sudo BASE_ISO=/path/to/kubuntu-26.04.1-desktop-amd64.iso ./build.sh
```

- Output goes to `out/`; intermediates go to `work/` (set `KEEP_WORK=1` to keep them for debugging).
- Both directories are ignored by `.gitignore`. **Do not** commit ISOs, split archives, checksum files or build directories.
- For changes touching build logic, describe the build/verification you performed in the PR.

## Opening a Pull Request

1. Push your branch to your fork and open a pull request against `main`.
2. Choose a template: the default [Chinese template](.github/PULL_REQUEST_TEMPLATE/chinese.md), or append `?quick_pull=1&template=english.md` to the compare URL for the [English template](.github/PULL_REQUEST_TEMPLATE/english.md).
3. Use a conventional commit style title, and fill in the change type, related issue, scope and testing details.
4. Ensure all required checks pass: `pr-check` (lint / preflight / secrets) and `dco`. CI re-runs the local checks on the PR.
5. First-time contributors without write access will be merged by a maintainer after CI passes; please respond to review feedback in a timely manner.

## Security and Privacy

- **Never run** `edit-grub/replace-grub.sh` without arguments (it overwrites `/boot/grub/grub.cfg`) or `edit-os-release/edit.sh` without a backup target (it overwrites `/etc/os-release` with no backup). In tests, use only the non-root fast-fail path or pass an explicit temporary target.
- `build.sh` performs `mount` / `chroot`, `apt` and PPA operations — run it as root only in an isolated environment. `--check` is a read-only preflight and is safe to run first.
- When adding tests, confine writes to a `mktemp -d` directory with a `trap` for cleanup; mock dangerous commands or pass them explicit temporary paths.
- Do not commit secrets, credentials or tokens (`gitleaks` scans for them).

## Code and Documentation Style

- Shell scripts use `set -euo pipefail`, 4-space indentation (`shfmt -i 4`) and LF line endings (see `.gitattributes`).
- Pure JS rule tests belong in `tests/*.test.js`; shell smoke scripts belong in `tests/`.
- Keep user-facing documentation in sync across languages: READMEs, issue templates and PR templates are all available in Chinese and English.

## License

This project is released under the **GNU Affero General Public License v3.0 only**. Opening a pull request means you agree to license your contribution under the same terms. See the [README](README.md#license--credits) for author and maintainer information, and [CONTRIBUTORS](CONTRIBUTORS) for the contributor list.
