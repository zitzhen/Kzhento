<!--
默认模板（自动填充）。英文版位于 .github/PULL_REQUEST_TEMPLATE/english.md。
若要用英文版新建 PR，请在 compare URL 后加参数：?quick_pull=1&template=english.md
-->

## 变更类型

<!--
标题请使用 conventional commit 格式，例如：
  feat(install-app): 新增 zsh 预装
  fix(boot): 修复 GRUB 启动超时
  docs: 更新 README
  ci: 调整 smoke test
  build: 修正 ISO 构建参数

自动打标脚本可识别的类型：
  feat / fix / docs / ci / build / refactor / perf / i18n / chore / deps / revert
也支持中文前缀：预装 / 新增 / 添加 / 增加 / 修复 / 重构 / 文档 / 说明 / 性能
-->

- [ ] `feat` 新功能 / 新预装应用
- [ ] `fix` 缺陷修复
- [ ] `docs` 文档
- [ ] `ci` CI / 自动化
- [ ] `build` 构建系统
- [ ] `refactor` 重构
- [ ] `perf` 性能优化
- [ ] `i18n` 国际化 / 本地化
- [ ] `chore` / `deps` 杂务 / 依赖更新

## 关联 Issue

<!-- 例如：Closes #123；无关联 issue 可写「无」 -->

Closes #

## 变更说明

<!-- 做了什么、为什么做。若改变行为，请说明对用户的影响。 -->

## 影响范围

<!-- 勾选涉及的目录，便于审查与自动打标。 -->

- [ ] `install-app/`（预装应用）
- [ ] `edit-grub/`（引导配置）
- [ ] `edit-os-release/`（系统信息 / 版本）
- [ ] `build.sh`（ISO 构建）
- [ ] `scripts/`（工具脚本）
- [ ] `.github/workflows/`（CI / 自动化）
- [ ] 文档（`*.md`）
- [ ] 其他：______

## 测试方式

<!-- 如何验证本次改动？贴上关键命令和结果。 -->

## 检查清单

<!-- PR Check 工作流会在 CI 中重新执行这些检查。 -->

- [ ] 标题使用 conventional commit 格式（影响自动打标）
- [ ] Shell 脚本语法检查通过（`bash -n` / `sh -n`）
- [ ] `shellcheck --severity=warning` 通过（若改动 `.sh`）
- [ ] `shfmt -d -i 4` 格式一致（若改动 `.sh`）
- [ ] `actionlint` 通过（若改动 workflow）
- [ ] `node --test tests/*.test.js` 通过
- [ ] `tests/check-version-consistency.sh` 通过——`build.sh` 的 `VERSION` 与 `edit-os-release/os-release` 的 `VERSION_ID` 一致
- [ ] `tests/preflight.test.sh` 通过
- [ ] `tests/terminal.test.sh` 通过
- [ ] 未提交任何密钥 / 凭据 / token（gitleaks）
- [ ] 所有 commit 已用 `git commit -s` 签名，且 `Signed-off-by` 邮箱是真实邮箱（非 noreply），符合 DCO 检查
- [ ] 涉及构建产物时，已核对 ISO / MD5 命名与版本号
