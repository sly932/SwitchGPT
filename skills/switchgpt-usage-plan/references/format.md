# SwitchGPT 使用计划文件格式 v1

`account-state.json` 保存 CLI v1 实时额度报告的可展示字段和手动套餐日期。每账号的 `subscription` 可包含 `expiresOn`（真实 YYYY-MM-DD 日期）、`source: "manual"`、`updatedAt`（含偏移的 ISO 时间）。未登记时无此字段。界面和技能都在这一个文件中修改日期，`capture` 保留最新手动值。手动编辑订阅信息时会更新 `revision` 和 `metadataUpdatedAt`，保留表示额度查询时间的 `generatedAt`。首次采集之前在界面登记日期时，快照的 `source` 为 `manual`，`generatedAt` 为 `null`，发布计划前仍需执行 `capture`。快照只保留展示字段，缺少卡明细时仍以已知库存总数为准。

发布 `usage-plan.json` 时，脚本同时核对 `snapshotGeneratedAt` 和 `snapshotRevision`。应用打开已发布计划时，以当前快照的 `revision` 判断是否过期，旧快照缺少 `revision` 时比较时间戳。`capture` 写入新快照或手动修改日期会产生新修订，单独运行 `switchgpt quota` 只返回查询结果。离线 HTML 内嵌发布时的快照与计划，更新后需重新打开生成的文件。

| 字段 | 用途 |
| --- | --- |
| `schemaVersion` | 固定为整数 `1` |
| `title`、`summary` | 用户能读懂的计划名称与摘要 |
| `generatedAt`、`snapshotGeneratedAt` | ISO 8601，包含时区偏移。计划生成时间不早于关联快照 |
| `snapshotRevision` | 与当前账号 JSON 的 `revision` 相同，手动日期改变后须重新排程 |
| `timeZone` | `Asia/Shanghai`。按用户当前时区展示 |
| `budget` | `currency: "USD"`、`monthlyLimit`、可选的自费上限 `selfPayLimit`（缺省为 0）、`plannedTotal`。续费节点合计须等于 `plannedTotal`，且不得超过报销与自费上限之和。已支付或剩余报销额度只有确认后再记录 |
| `planningContext` | 用户提供的计划依据。推荐 `billingMonth`、`usage`、`uncertainties`。套餐到期从账号 JSON 读取，旧版本 `subscriptionFacts` 仅作历史依据，不再作为独立可编辑源 |
| `entries` | 按 `startAt` 升序排列的未来操作与使用时段 |

每项含 `kind`、`startAt`、`title`。可加 `note`，说明触发条件、跳过后的安排和复查动作。账号用 `account` 对应快照的邮箱。

| `kind` | 补充字段与含义 |
| --- | --- |
| `use` | `account`、`speed`（`standard`、`fast`、`as-needed`），以及二选一的 `endAt` 或 `endWhen`。前者是固定时段，后者为可读的结束条件，例如“当前额度耗尽或实际会员权限失效”。条件结束的使用段之后不再排固定使用段，后备顺序写在该段说明或检查节点中，等条件实际发生再重排 |
| `card` | `account`、`cardExpiresAt`，必须匹配该号实时报告的一张已知卡。时点早于到期。后接对应的使用时段，或明确何时转回该账号 |
| `renew` | `account`、`amountUsd`。办理节点，结算时间、价格与已付款状态以用户确认或结算页为准 |
| `check` | 可选 `account`。用于核实信息、检查缺口或观察库存，不代表兑换或扣款 |

排程按以下原则判断：

- Plus 套餐账号只保留在账号快照与账号总览中，不加入 `entries`，不参与可用额度及计划支出计算。按最新 `planName` 识别 `Plus` 或 `ChatGPT Plus`，忽略大小写及多余空格。账号改为其他套餐后，下一次重新生成计划再按实际套餐处理。
- 先看真实待办和快照时间。把自然重置、订阅到期、卡到期、点数有效期分别处理。只排当下可执行的节点，较远日期适合检查点和明确的切换条件。
- 登记到期日已过但实时仍返回 Pro 时，保留手动日期并注明当前观察。用户要求用到额度耗尽或权限失效时，用 `endWhen` 表达结束条件，不编造延续天数或固定切号时刻；提供后备账号顺序与复查节点。额度耗尽即先退出当前段，后续自然重置不自动算作恢复可用，须重新核实会员、额度和实际模型权限。长期卡和续费按真实缺口判断。
- 实际有任务时，优先使用更早自然重置或结束的额度。平时标准速度，临近失效且有实际任务、或任务赶时间时才建议 Fast。额度百分比不能跨套餐直接换算成可用时长。
- 卡片检查点必须标明条件和截止时间。已满额度跳过；将自然重置时优先等待或轮换。近期到期卡只有实际能补回额度时才值得处理。成功后刷新、记录真实结果和新的自然重置时间，再使用恢复的额度；不能把重置、升级和自然重置算成可叠加额度。
- 降档前用卡只有能在降档前实际消费补回额度时才有收益。断订后的卡、点数和模型可用性以账号实际显示为准。不要为了保卡自动新增订阅。
- 已经过去的节点、已无法确认的卡和失败账号不要写成执行指令。首次计划和每次更新都标出快照时间与需要用户核实的付款、订阅事实。
