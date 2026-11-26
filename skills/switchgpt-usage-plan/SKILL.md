---
name: switchgpt-usage-plan
description: 根据 SwitchGPT 当前账号额度、自然重置时间、重置卡、套餐到期和预算生成或更新使用计划，并保存本地账号快照、计划 JSON 与可离线打开的 HTML。适用于“更新使用计划”“重新排切号、Fast、用卡或续费时间表”；单纯查余额使用 switchgpt-accounts。
---

# SwitchGPT 使用计划

账号快照记录查询事实。使用计划记录未来的建议动作。两者分别保存，HTML 从同一份计划和关联快照生成。

Plus 套餐账号保留在完整账号快照中，但排除在使用计划之外。以最新查询的 `planName` 判断，`Plus` 和 `ChatGPT Plus` 均排除，不为其安排使用、切号、Fast、重置卡、续费或单账号检查节点，也不计入计划可用额度与计划支出。套餐未知时不得猜测为 Plus。维护本技能规则本身不触发账号查询或到期时间更新询问。

1. 每次使用本技能都先问用户是否需要更新账号到期时间，提供“沿用 JSON 中现有日期”和“更新到期时间”两项。若用户本次请求已明确提供日期或明确说沿用，可直接按其指示处理。等待回答期间可查询额度，回答到达后再完成本轮计划。用户选择更新时收集账号和 YYYY-MM-DD 日期，用下述 `set-expiry` 写入；没有回答时不擅自改日期或把超时当作选择。
2. 读取 [switchgpt-accounts](../switchgpt-accounts/SKILL.md)，按其口径使用实时 `switchgpt quota`。用本技能 [usage_plan.py](scripts/usage_plan.py) 的 `capture` 命令执行查询并保存允许展示的字段。它保留最新的手动到期日。查看逐账号状态和快照时间；失败时不能拿旧值冒充新值。
3. 以 `account-state.json` 的 `accounts[].subscription` 为到期时间的唯一来源，结合当前对话和上次计划的 `planningContext` 核对续费目标、报销预算、实付及使用习惯。自动额度接口不提供订阅到期、付款或已兑换卡的历史。用户给出新日期时先写回同一份 JSON，界面和技能都从它读取。不要用旧计划的日期覆盖新手动日期，或把日期补成未经确认的到期小时。
4. 按 [数据格式和排程规则](references/format.md) 生成计划。使用时段、切号、用卡、续费按一条时间线排序。会员延续结束时间未知且用户要求用完或失效再切换时，使用 `endWhen` 条件结束，不强设切号时间。明确每张卡属于哪个账号、何时检查、卡何时到期、成功后哪个时段使用该账号。过去的时间点从新计划移除，不猜测是否已执行。
5. 在临时目录写入计划草稿，记录最新 `snapshotGeneratedAt` 和 `snapshotRevision`，用 `publish <draft>` 校验并生成计划 JSON 与离线 HTML。校验失败就修正草稿；若期间有人在界面修改日期，以新 JSON 重新排程。检查生成的文件和关键操作点，回给用户 HTML 链接与需要注意的变化。

```sh
python3 ~/.agents/skills/switchgpt-usage-plan/scripts/usage_plan.py capture
python3 ~/.agents/skills/switchgpt-usage-plan/scripts/usage_plan.py set-expiry user@example.com --date 2026-12-09
python3 ~/.agents/skills/switchgpt-usage-plan/scripts/usage_plan.py set-expiry user@example.com --clear
python3 ~/.agents/skills/switchgpt-usage-plan/scripts/usage_plan.py publish /绝对路径/计划草稿.json
```

本地输出在 `~/Library/Application Support/SwitchGPT-sly/UsagePlan/`。应用已有使用计划页面，可读取发布的 HTML 和对应 JSON，并提示计划是否需要更新。技能负责生成建议和更新这些本地文件，登录、切号、兑换和付款由用户执行。测试时可在子命令前用 `--directory` 指定独立输出目录，并让 `PATH` 中的 `switchgpt` 返回模拟报告。账号快照、计划草稿和生成的 HTML 只保存在本地，技能目录只存放脚本、说明和空白模板。
