# SwitchGPT 项目背景与工作区约定

## 项目背景

- SwitchGPT 是 macOS 上的 SwiftUI 工具，用于查看多个本机 ChatGPT 账号的套餐与 Work/Codex 额度，并提供经过确认的桌面账号切换流程。功能和安全边界以当前代码、`README.md`、`CONTRIBUTING.md` 为准；文档与实现不一致时先核查，不自行推断。
- 应用界面主要位于 `Sources/SwitchGPTApp/`，账号、额度与持久化模型主要位于 `Sources/SwitchGPTAppCore/`。测试位于 `Tests/`。不要将本地认证文件、账号目录、token 或运行日志加入版本控制。

## 分支与 worktree 流程

- `main` 跟踪公开仓库的 `origin/main`，用作上游基线。本项目个人修改的集成分支是 `shenliyuan`，固定工作区为 `~/projects/_worktrees/SwitchGPT/main-shenliyuan/`。worktree 名称是 `main-shenliyuan`，其中检出的 Git 分支名是 `shenliyuan`，两者不要混淆。
- 之后每项独立修改都从最新的本地 `shenliyuan` 创建任务分支和单独的 worktree，放在 `~/projects/_worktrees/SwitchGPT/<任务名>/`。在任务 worktree 中开发、验证，再把任务分支合并到 `shenliyuan`；不要直接在 `main` 或 `main-shenliyuan` 工作区开发普通功能。
- 合并前检查来源分支、目标分支、未提交改动和测试结果。合并只更新本地 `shenliyuan`；推送远端、合并到 `main`、发布版本都需要各自明确的请求。
- 原有 `~/projects/SwitchGPT` 工作区中的未提交改动属于原工作区，不会自动进入新 worktree。处理这些改动前先确认归属与目标，不能擅自丢弃、搬移或合并。

## 功能改动后的本机安装

- 每次功能修改在任务 worktree 完成验证并合并到本地 `shenliyuan` 后，都要从 `~/projects/_worktrees/SwitchGPT/main-shenliyuan/` 重新编译，并更新安装 `~/Applications/switchgpt-sly.app`。只运行 `swift build`、打开 `.build/dev-app` 中的临时包，或只提交代码，都不算完成本机交付。
- 已安装时运行 `./script/build_and_run.sh --reinstall`；首次安装才运行 `--install`。重新安装必须先构建和验证新包，再停止旧的 `switchgpt-sly` 进程、替换应用，并保留可恢复的旧包。不能删除或覆盖 `~/Library/Application Support/SwitchGPT-sly` 中的账号数据；安装失败时恢复原应用。
- 安装后从 `~/Applications/switchgpt-sly.app` 打开，核对实际运行的包、已添加账号和本次修改的可见行为，并报告构建、测试、安装及验收结果。若因环境限制无法完成安装或验收，要明确说明，不能声称功能已可在已安装应用中使用。
