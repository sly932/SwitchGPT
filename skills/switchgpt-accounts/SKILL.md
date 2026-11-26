---
name: switchgpt-accounts
description: 使用本机 SwitchGPT CLI 查询所有已添加 ChatGPT 账号的套餐、剩余额度、额度重置时间、credits、重置卡及 Token 用量，解释或展示实际 JSON。适用于“所有账号还剩多少额度”“查账号用量”“switchgpt quota/usage”；不负责登录、账号切换、兑换重置卡或查询 API 平台账单。
---

# SwitchGPT 账号查询

SwitchGPT 将这台 Mac 上已添加的多个 ChatGPT 账号保存在本地。此技能用 `quota` 和 `usage` 查询所选状态文件中保存的账号。

## 选择并运行命令

| 用户意图 | 命令 |
| --- | --- |
| 最新剩余额度、套餐、重置卡、所有账号状态 | `switchgpt quota` |
| 完整已支持用量、累计或每日 Token 统计 | `switchgpt usage` |
| 已保存快照、离线查询或用户明确要求缓存 | `switchgpt quota --cached` 或 `switchgpt usage --cached` |
| 查看当前安装版本支持的参数 | `switchgpt --help` |

默认实时查询，Dashboard 无需正在运行。`quota` 跳过 Token 历史查询；只有需要用量统计时才使用 `usage`。

```sh
switchgpt quota
switchgpt usage
switchgpt quota --cached
switchgpt usage --timeout 30
switchgpt quota --state-file '/绝对路径/preview-state.json'
```

- `--timeout` 是每账号实时读取超时，整数 1–120 秒，默认 20 秒。当前最多同时查询 4 个账号，总耗时可能超过单账号超时。
- `--state-file` 指定另一份私有状态文件；默认是 `~/Library/Application Support/SwitchGPT-sly/preview-state.json`。不要为了查看数据而直接输出该文件，文件可能包含未在 CLI 报告中公开的本地路径等元数据。
- `--cached` 读取默认状态文件时，会优先使用同一账号档案的较新后台快照。后台快照不可用时读取原有记录。指定其他状态文件时，读取该文件中保存的快照。
- `quota` 和 `usage` 不写入 Dashboard 快照或认证凭据。`refresh` 会写入 Dashboard 快照，并可能续期符合条件的托管凭据。查询时只使用 `quota` 和 `usage`。

先用 `command -v switchgpt` 找到入口。若 PATH 未包含它，优先使用：

```sh
/Applications/switchgpt-sly.app/Contents/Helpers/switchgpt quota
```

也可检查 `~/.local/bin/switchgpt`，或旧版用户级安装 `~/Applications/switchgpt-sly.app/Contents/Helpers/switchgpt`。若均不存在，需要安装包含 CLI 的应用构建。旧的公开 `0.2.3` 包没有 CLI。用户明确要求安装命令入口时，从此技能所在仓库的根目录运行：

```sh
./script/install-cli.sh
```

该脚本将 `~/.local/bin/switchgpt` 链接到已安装应用的 CLI，遇到不同的现有命令会保留它并报错。无需将二进制或认证材料复制进 skill。实现与安装位置变更时以实际 `--help`、安装包和源码为准。

## 解释 JSON

标准输出是一份 JSON，顶层 `schemaVersion` 当前为 `1`：

| 字段 | 含义 |
| --- | --- |
| `command` | `quota` 或 `usage` |
| `source` | `live` 为本次实时查询，`cache` 为应用先前保存的快照 |
| `generatedAt` | 报告生成时间；缓存报告的生成时间不等于数据刷新时间 |
| `totalCount` | 本次返回账号数，按状态文件保存顺序排列 |
| `errorCount` | `status=error` 的账号数 |
| `partialCount` | `status=partial` 的账号数 |
| `accounts[]` | 一个元素代表一个已保存账号及本次查询状态 |

账号元素含 `id`、`displayName`、可选 `email`、`planName`、`status`、可选 `refreshedAt`、`quota`、`usage` 和 `error`。

- `quota.weekly` 和可选 `quota.fiveHour`：`usedPercent` 为已用百分比，`remainingPercent` 为剩余百分比，`resetAt` 为额度重置时间。额度是百分比，不能换算成剩余 Token 数。
- `refreshedAt` 为成功读取该账号快照的时间。实时成功时为本次读取时间；缓存时为保存的刷新时间；失败时如存在，仅为历史保存时间。
- `planName` 是套餐名称，没有订阅续费或到期时间。失败账号的套餐和邮箱也只来自保存记录，不能称为最新套餐状态。
- `quota.credits` 包含 `hasCredits`、`unlimited`、可选 `points`。`points` 的单位为 credit points，不是美元。若需与当前 GUI 一致的展示值，项目模型采用 `points × 0.04` 美元；这不代表账单、退款金额或 API 平台余额，换算前应核对当前模型。
- `quota.resetCredits.availableCount` 是权威可用重置卡总数，`credits[]` 只有已返回的到期元数据。`expiresAt` 为该卡到期时间；明细条数可能少于总数，缺失时间不能猜测。CLI 不输出兑换标识，也不支持兑换。
- `quota.creditsWereLoaded` 和 `quota.resetCreditsWereLoaded` 表示是否已检查相应数据。标记为 `true` 时，余额或到期明细仍可能缺失。`usage` 的 `ok` 或 `partial` 账号会带 `accounts[].tokenActivityWasLoaded`。字段缺失或 `null` 表示未知，不能当作 0。五小时额度缺失时保留未知状态。
- 时间格式为 ISO 8601 UTC，尾部 `Z` 表示 UTC。面向用户汇总时按用户时区显示；要求原始 JSON 时保留原值。

`usage` 命令额外返回 `usage` 对象中的服务端统计：

| 字段 | 含义 |
| --- | --- |
| `lifetimeTokens` | 累计 Token 数 |
| `peakDailyTokens` | 单日峰值 Token 数 |
| `longestRunningTurnSec` | 最长单轮运行秒数 |
| `currentStreakDays`、`longestStreakDays` | 当前、最长连续使用天数 |
| `dailyUsageBuckets[]` | 每日记录，每项含日期 `startDate` 和 Token 数 `tokens` |

“完整用量”仅指当前解码器支持并由服务端返回的这些统计，不含逐条对话、消费账单或所有历史数据的保证。未返回的日期不能补成零。

## 失败与退出码

| 结果 | 处理方式 |
| --- | --- |
| `status=ok` | 展示该命令已读取的数据；可选字段仍可能未知 |
| `status=partial` | 额度可用但 Token 统计未加载，保留额度并说明 `token_activity_unavailable` |
| `status=error` | 保留该账号及 `error.code/message`，不返回旧额度冒充实时数据 |
| 退出 `0` | 仅表示报告成功生成；即使全部账号失败也可能为 `0`，仍须检查逐账号状态和计数 |
| 退出 `1` | 状态文件读取或输出失败；错误 JSON 写到 stderr |
| 退出 `2` | 参数错误；错误 JSON 写到 stderr，核对 `--help` |

状态文件不存在时返回 `accounts: []`；文件损坏、私有权限不符合要求或整体校验失败时，命令级失败。单账号查询失败隔离不意味着能容忍损坏的账号列表文件。

常见账号错误：`timed_out`、`missing_codex_binary`、`identity_mismatch`、`missing_authentication_file`、`invalid_protocol_response`、`query_failed`；缓存无成功刷新时间时为 `no_cached_snapshot`。不能仅凭通用错误码推断已过期、被封禁或责任人。网络超时可有界重试一次；持续失败则列出失败账号与错误，不无限重试、不自动改认证或放宽权限。

若桌面重新登录后托管账号仍查询失败，可建议在 SwitchGPT 应用中手动刷新以同步凭证；不要读取或打印 `auth.json`、token、Cookie、身份哈希或账号目录来替代查询。

## 展示结果

用户要求“实际 JSON”时运行相应命令并展示完整实际输出，不用示例替代、不静默省略失败账号。普通额度问题则优先简表：账号、套餐、周剩余、额度重置时间、重置卡总数、最近已知到期时间、状态，并说明实时或缓存、数据刷新时间。

筛选示例（需安装 `jq`）：

```sh
switchgpt quota | jq '.accounts[] | {email, planName, status, refreshedAt, weekly: .quota.weekly, resetCredits: .quota.resetCredits, error}'
switchgpt usage --cached | jq '{source, generatedAt, totalCount, errorCount, partialCount}'
```

汇总必须保留失败或部分成功状态；不把缺失值算作零或纳入没有说明的总量。原始输出含邮箱，按用户请求在当前对话展示可以；不会因此自动取得上传、发送给他人或长期归档的授权。skill 内只维护用法，不保存真实账号列表或运行结果。

## 实现核查入口

需核查参数或字段时，从符号链接实际指向的技能目录打开仓库内的对应文件：

- [SwitchGPTCLI.swift](../../Sources/SwitchGPTCLI/SwitchGPTCLI.swift) 的参数、默认数据源和退出码。
- [AccountReport.swift](../../Sources/SwitchGPTAppCore/Services/AccountReport.swift) 的输出结构和失败隔离。
- [AccountModels.swift](../../Sources/SwitchGPTAppCore/Models/AccountModels.swift) 的额度、重置卡、Token 统计和 credit points 换算。
- [README.md](../../README.md) 的「命令行查询所有账号」。
