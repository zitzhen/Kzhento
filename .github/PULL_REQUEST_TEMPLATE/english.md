<!--
English template. To open a PR with this template, add to the compare URL:
?quick_pull=1&template=english.md
-->

## Type of change

<!--
Please use conventional commit style in the PR title, for example:
  feat(install-app): add zsh to preinstalled apps
  fix(boot): fix GRUB boot timeout
  docs: update README
  ci: adjust smoke test
  build: correct ISO build parameter

The auto-label script recognizes these types:
  feat / fix / docs / ci / build / refactor / perf / i18n / chore / deps / revert
Chinese prefixes are also supported: 预装 / 新增 / 添加 / 增加 / 修复 / 重构 / 文档 / 说明 / 性能
-->

- [ ] `feat` New feature / new preinstalled app
- [ ] `fix` Bug fix
- [ ] `docs` Documentation
- [ ] `ci` CI / automation
- [ ] `build` Build system
- [ ] `refactor` Refactoring
- [ ] `perf` Performance improvement
- [ ] `i18n` Internationalization / localization
- [ ] `chore` / `deps` Chore / dependency update

## Related issue

<!-- e.g. Closes #123; write "none" if there is no related issue -->

Closes #

## Description

<!-- What was changed and why. If behavior changes, describe the impact on users. -->

## Scope

<!-- Check the areas touched, to help review and auto-labeling. -->

- [ ] `install-app/` (preinstalled apps)
- [ ] `edit-grub/` (boot configuration)
- [ ] `edit-os-release/` (system info / version)
- [ ] `build.sh` (ISO build)
- [ ] `scripts/` (utility scripts)
- [ ] `.github/workflows/` (CI / automation)
- [ ] Documentation (`*.md`)
- [ ] Other: ______

## How to test

<!-- How can this change be verified? Include key commands and results. -->

## Checklist

<!-- The PR Check workflow re-runs these checks in CI. -->

- [ ] PR title uses conventional commit style (affects auto-labeling)
- [ ] Shell syntax checks pass (`bash -n` / `sh -n`)
- [ ] `shellcheck --severity=warning` passes (if `.sh` files changed)
- [ ] `shfmt -d -i 4` reports no diff (if `.sh` files changed)
- [ ] `actionlint` passes (if workflows changed)
- [ ] `node --test tests/*.test.js` passes
- [ ] `tests/check-version-consistency.sh` passes — `VERSION` in `build.sh` matches `VERSION_ID` in `edit-os-release/os-release`
- [ ] `tests/preflight.test.sh` passes
- [ ] `tests/terminal.test.sh` passes
- [ ] No secrets / credentials / tokens committed (gitleaks)
- [ ] Every commit is signed with `git commit -s`, and the `Signed-off-by` email is a real address (not noreply), per the DCO check
- [ ] When build artifacts are affected, ISO / MD5 filenames match the version
