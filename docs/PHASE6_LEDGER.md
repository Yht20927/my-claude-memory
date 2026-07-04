# mcMemory Phase 6 — 会话决策日志（Session Ledger）

> **目标**：为 mcm 增加结构化、跨会话、append-only 的决策/待办日志，补齐"AI 上下文跨会话存活"使命中缺失的一环。
> **基线版本**：v3.5（172 项测试全绿，inject 路径惰性求值已落地）
> **预计规模**：1 个新库 + 1 个新命令 + 1 处 SessionStart 注入 + 1 套集成测试
> **撰写日期**：2026-07-04

---

## 0. TL;DR

mcm 当前能持久化**知识**（L1-L4 chunks）和**操作记录**（op-log），但缺一类关键产物：**结构化决策与待办的跨会话日志**。

| 已有 | 形态 | 跨会话？ | 结构化？ | 触发 |
|------|------|----------|----------|------|
| L1-L4 chunks | 浓缩知识 | 是 | 半结构（frontmatter） | sync/init（被动） |
| PreCompact `session_*.md` | 会话叙事摘要 | 是（归档为 chunk） | 否（自由文本） | 上下文压缩时（被动） |
| `mcmJournal` | 一行自由笔记 | 否（滚进 session_notes→PreCompact） | 否 | AI 主动 |
| op-log `log.md` | **mcm 命令**操作时间线 | 是 | 是（`## [ts] op (actor)`） | 写操作自动 |
| **ledger（本提案）** | **决策/blocker/todo/learning** 日志 | **是** | **是（typed + status）** | **AI 主动 / 可查** |

**GAP**：新会话开始时，AI 看不到"上次这个项目决定到哪了、卡在哪、还欠什么 todo"。PreCompact 只在压缩时存叙事摘要，不是结构化、不可查的待办流。Ledger 填这个洞。

---

## 1. 动机与目标

### 1.1 痛点（实测场景）

- 开发者跨天回到同一项目，AI 冷启动后**不知道**昨天卡在"B2 修复"还是"已经合了"。
- `mcmJournal` 写的笔记要等 PreCompact 才归档为 chunk，且归档后淹没在 L3 里，**无法按 status=open 查**。
- op-log 只记 mcm 自己干了什么（init/sync/restore…），**不记业务决策**。
- drift 报告能说"这个 chunk 30 天没动"，但说不出"这个 blocker 挂了 30 天没解"。

### 1.2 目标（G1-G5）

- **G1**：每个记忆目录新增 `<memory>/ledger.md`，append-only、不可变、grep 友好。
- **G2**：`mcmLedger` 命令：`add` / `list` / `resolve` / `show`，支持 `--type` / `--status` / `--since` / `--json` 过滤。
- **G3**：SessionStart 自动注入最近 N 条**未关闭** todo/blocker，让新会话承接未竟之事。
- **G4**：复用主干，不引入新依赖——op-log 的 `## [ts] type (actor)` 格式、mcmMark 的 source/evidence 信任层、NDJSON 事件总线、纯 Bash + 内联 Python。
- **G5**：append-only 不可变（event-sourcing 风格）——状态变更通过新条目（`done` + `resolves:`）而非编辑旧条目。

### 1.3 非目标

- ❌ 不做任务依赖图 / 甘特（不是项目管理工具）。
- ❌ 不替代 `mcmJournal`（journal 仍是自由叙事，ledger 是结构化日志）。
- ❌ 不从对话自动抽取决策（AI 显式调用 `mcmLedger add`）。
- ❌ 不新增记忆层级（ledger.md 是 sidecar 文件，非 L5）。
- ❌ ledger 不进 BM25 搜索索引（时序/结构化检索 ≠ 语义检索；提供 `mcmLedger list` 即可）。

---

## 2. 数据模型

### 2.1 文件布局

```
<memory>/
├── summary.md          (L1)
├── index.md            (L2)
├── chunks/*.md         (L3)
├── .claude/            (L4)
├── hash.json
├── log.md              ← op-log（mcm 命令操作时间线）
└── ledger.md           ← 【新】决策/待办日志（业务时间线）
```

`log.md`（mcm 干了什么）与 `ledger.md`（项目决定了什么）职责分离、格式同构。

### 2.2 条目格式

复用 op-log 的 header 约定，扩展字段：

```markdown
# 决策日志

## [2026-07-04T23:00:00] decision (user)
采用 BM25 替代向量检索做召回
context: 中文长尾召回 bigram 已够用；向量引入运维成本高于收益
refs: chunks/1_ARCHITECTURE.md

## [2026-07-04T23:05:00] blocker (agent)
中文 bigram 在 2 字虚词上误召回（"我们"/"这个"）
status: open

## [2026-07-04T23:30:00] todo (user)
实现 mcmLedger list --status open
status: open

## [2026-07-04T23:45:00] done (user)
完成 ledger MVP
resolves: 2026-07-04T23:30:00
```

### 2.3 字段规范

| 字段 | 必需 | 说明 |
|------|------|------|
| `## [ISO8601] <type> (<actor>)` | 是 | header；type ∈ `decision\|blocker\|todo\|learning\|done\|note`；actor ∈ `user\|agent\|system` |
| 正文一行摘要 | 是 | header 后第一行，一句话 |
| `context:` | 否 | 缩进多行，补充背景 |
| `status:` | 否 | `open\|resolved\|superseded`；todo/blocker 默认 `open`，decision/learning 默认 n/a |
| `resolves:` | 否 | 引用被关闭条目的 ISO8601（done/resolved 条目用） |
| `refs:` | 否 | 指向 chunks/ 或源文件，逗号分隔 |

**条目 ID = ISO8601 时间戳**（按记忆内唯一、可排序）。同一秒冲突时追加 `_2`、`_3`（复用 `move_to_trash` 的碰撞规避模式）。

### 2.4 不可变语义（event-sourcing）

- **绝不编辑既有条目**。状态流转通过追加新条目实现：
  - 关闭 todo：append `done` 条目，带 `resolves: <orig-ts>`。
  - `list --status open` 的计算：`open 集合 = (status=open 的条目) − (被某条 resolves: 引用的条目)`。
- 这与 op-log、trash 的 append-only 哲学一致，可审计、无丢失更新。

---

## 3. 命令设计

### 3.1 `mcmLedger add <type> <text>`（默认子命令，可省略 `add`）

```
mcmLedger decision "采用 BM25 替代向量检索"
mcmLedger todo "实现 ledger list" --context "需要 --status 过滤"
mcmLedger blocker "bigram 误召回" --refs chunks/1_SEARCH.md
mcmLedger learning "flock fd 自动分配在 bash 4.1+ 才稳"
echo "多行 context" | mcmLedger note "标题" --stdin
```

**flags**: `--memory <名>`（默认当前 workspace 项目记忆）/ `--global` / `--context <文本>` / `--stdin` / `--refs <路径>` / `--actor user|agent|system`（默认 user）/ `--workspace PATH`

**行为**：
1. 定位记忆（复用 `find_project_memory_dir` / `find_memory_path`，透传 `--name`）。
2. 取锁（`acquire_lock "ledger_<name>"`）。
3. 生成 ISO8601 时间戳；冲突则 `_2`。
4. append 条目到 `<memory>/ledger.md`（文件不存在则建 `# 决策日志` 头）。
5. `emit_event "ledger.add" type=<type> memory=<name>`。
6. `log_memory_op "$mem" "ledger" "type=$type add"`（op-log 接入，保持 8→9 个写操作覆盖）。

### 3.2 `mcmLedger list`

```
mcmLedger list                              # 全部
mcmLedger list --type todo --status open    # 待办
mcmLedger list --since 7                    # 最近 7 天
mcmLedger list --limit 5                    # 最近 5 条
mcmLedger list --json                       # 机器可读
```

**输出（文本）**：

```
## ledger: myproj (12 条, 3 open)

| 时间 | 类型 | 状态 | 摘要 |
|------|------|------|------|
| 2026-07-04T23:30 | todo | open | 实现 mcmLedger list --status open |
| 2026-07-04T23:05 | blocker | open | bigram 误召回 |
| 2026-07-04T23:00 | decision | — | 采用 BM25 替代向量检索 |
```

`--status open` 默认排除 `done`/`resolved`/被 `resolves:` 引用的条目（event-sourcing 计算）。

### 3.3 `mcmLedger resolve <id> [note]`

```
mcmLedger resolve 2026-07-04T23:30:00 "已实现，见 commit abc123"
```

append 一条 `done` 条目，`resolves: <id>`，actor=user。不编辑原条目。

### 3.4 `mcmLedger show <id>`

打印单条目全文（含 context/refs）。

### 3.5 退出码与错误

- 记忆不存在 → exit 1 + 中文错误（沿用现有约定）。
- `resolve` 的 id 不存在 → exit 1。
- 无 ledger.md → `list` 打印"（无决策日志）"并 exit 0（非错误）。

---

## 4. SessionStart 注入

### 4.1 行为

`session_start_inject`（lib/inject.sh）在加载 L1 + auto L3 之后，追加：

```
<!-- mcMemory ledger: open items -->
> **未竟事项**（3 open, 最近 7 天）:
> - [todo] 2026-07-04 实现 mcmLedger list --status open
> - [blocker] 2026-07-04 bigram 误召回
> - [todo] 2026-07-03 修 B7 全局前缀
<!-- /mcMemory ledger -->
```

### 4.2 配置

| 环境变量 | 默认 | 说明 |
|----------|------|------|
| `MCM_LEDGER_INJECT` | `1` | `0` 关闭 ledger 注入 |
| `MCM_LEDGER_INJECT_COUNT` | `5` | 最多注入几条 open |
| `MCM_LEDGER_INJECT_TYPES` | `todo,blocker` | 注入哪些类型 |
| `MCM_LEDGER_INJECT_SINCE_DAYS` | `14` | 只注入近 N 天 |

### 4.3 与 kill-switch 的关系

- 全局 STOP（`.stop`）→ 整个 SessionStart 短路，ledger 也不注入。
- pause（`.paused_until`）→ 同上。
- ledger 注入**不**走 prompt_submit 的 BM25/cooldown 路径——它是 SessionStart 的一部分，确定性注入（最近 N 条 open），不参与相关性打分。

---

## 5. 复用与集成点

| 既有机制 | ledger 如何复用 |
|----------|----------------|
| op-log `## [ts] op (actor)` 格式 | ledger 条目同构，`grep '^## \[' ledger.md` 即时间线 |
| `log_memory_op()` | ledger add/resolve 调用之，op-log 记 `ledger` 操作 |
| `acquire_lock` / `mcm_on_exit` | ledger 写操作取锁，trap 释放 |
| `emit_event` / NDJSON 总线 | emit `ledger.add` / `ledger.resolve` |
| `find_project_memory_dir` / `.workspace` 标记 | ledger 定位记忆，支持 `--name` |
| `mcm_run_command` | mcmLedger 命令包裹 cmd.start/end 事件 |
| drift 报告（可选 §7） | flag "open blocker > N 天" 为 drift 信号 |
| 纯 Bash + 内联 Python | list/parse 用 Python，IO 用 Bash，无新依赖 |

---

## 6. 实现步骤

### 6.1 新增 `lib/ledger.sh`

```
ledger_path()                 # <memory> → <memory>/ledger.md
ledger_add()                  # mem type text actor context refs → 追加条目，echo id
ledger_parse()                # ledger.md → Python 解析为 [{id,type,actor,summary,status,refs,resolves,ts_raw}]
ledger_list()                 # 应用 filter（type/status/since/limit）→ 表格/json
ledger_open_entries()         # event-sourcing 计算 open 集合
ledger_resolve()              # append done + resolves:
ledger_entries_for_inject()   # SessionStart 用：近 N 天 open todo/blocker，限 M 条
```

解析用单次 Python（`## [ts] type (actor)` header + `status:`/`resolves:`/`refs:`/`context:` 字段），复杂度 O(n)。

### 6.2 新增 `commands/ledger.sh`（`mcmLedger`）

按 `commands/update.sh` 模式：parse_args → step1_detect → step2_action → step3_log → lock/release → `mcm_run_command main`。

### 6.3 改 `lib/inject.sh` `session_start_inject`

在 auto L3 循环后、return 前，加：
```bash
# v3.6: ledger open items 注入
if [ "${MCM_LEDGER_INJECT:-1}" = "1" ] && ! is_inject_stopped && ! is_inject_paused; then
    output+="$(_ledger_inject_block "$project_dir")"
fi
```
`_ledger_inject_block` 在 ledger.sh，读 `MCM_LEDGER_INJECT_*`，调 `ledger_entries_for_inject`。

### 6.4 测试 `tests/integration/test_phase6.sh`（约 18-22 断言）

| it | 覆盖 |
|----|------|
| `ledger add writes structured entry` | add → 文件存在、header 格式、字段正确 |
| `ledger list filters by type/status/since` | 多条目混合，过滤命中 |
| `ledger resolve appends done + resolves` | 原条目不变，新 done 条目带 resolves |
| `list --status open computes open set` | resolve 后原条目从 open 集消失 |
| `SessionStart injects open todos` | 新会话输出含 open todo，不含已 resolve |
| `STOP/pause suppresses ledger inject` | kill-switch 生效 |
| `ledger immutability` | resolve 不编辑原条目（hash 不变） |
| `ledger add op-log + event` | log.md 含 `ledger`，events 含 `ledger.add` |
| `ledger absent → list 非错误` | 无 ledger.md 时 list exit 0 |

### 6.5 文档

CLAUDE.md / README.md / SKILL.md → v3.6；SKILL.md 命令表加 `mcmLedger`；AI 浓缩指令补一条"决策时调 `mcmLedger decision`"。

### 6.6 提交

单 commit：`feat(ledger): 会话决策日志 + SessionStart 注入 (v3.6 Phase 6)`，推 main。

---

## 7. 可选增强（非 MVP，留作 Phase 6.x）

- **drift 集成**：`mcmStatus --drift` 把"open blocker 超 N 天"列为 drift 信号（扣分 -3/条），让陈旧债务可见。
- **ledger archive**：`mcmLedger archive --before DAYS` 把已 resolve 的旧条目移到 `ledger.archive.md`，控制主文件增长。
- **refs 反向链接**：chunk frontmatter 反向显示"被 ledger 条目引用"——双向追溯。
- **`mcmSearch ledger`**：让 `mcmSearch` 可选扫 ledger.md（当前非目标，但未来若需全文查决策可加 `--scope ledger`）。
- **频率加权注入**：基于 NDJSON `ledger.add` 事件统计高频 topic，给相关记忆 BM25 加权（与 §8 候选 C 交叉）。

---

## 8. 风险与权衡

| # | 风险 | 缓解 |
|---|------|------|
| R1 | ledger 与 mcmJournal 职责重叠，用户困惑 | 文档明确：journal=自由叙事→chunk；ledger=结构化决策→sidecar。SKILL.md 给"何时用哪个"决策树 |
| R2 | SessionStart 注入挤占 token 预算 | `MCM_LEDGER_INJECT_COUNT` 默认 5、`SINCE_DAYS` 默认 14；超预算时截断并提示 |
| R3 | append-only 无限增长 | MVP 接受（文本，量小）；Phase 6.x 加 `archive` |
| R4 | 时间戳碰撞 | 复用 trash 的 `_2/_3` 后缀模式 |
| R5 | 用户不主动 add → ledger 空 | 这是预期：ledger 是 opt-in 主动工具；PreCompact/journal 仍兜底被动捕获 |
| R6 | resolve 后原条目仍 `status: open` 字面 | list 计算 open 集时用 event-sourcing（减去 resolves 引用），而非读 status 字面值；文档说明 |

---

## 9. 其他候选方向（未来 Phase，非本步）

供后续选型参考，按价值/风险排序：

| 候选 | 价值 | 风险 | 一句话 |
|------|------|------|--------|
| **C. 频率/近因加权注入** | 中-高 | 低 | 用 NDJSON inject 事件统计每记忆被注入频次，给 BM25 加 recency×frequency boost。纯数据驱动，无新 UI |
| **D. 衰减/遗忘** | 中 | 中 | 超 N 天未访问的记忆权重衰减或归档；mex 风格。需小心误删用户重要记忆 |
| **E. mcmDiff** | 中 | 低 | 利用 hash.json 历史展示记忆两次 sync 间的变更（哪些 chunk 新增/改动） |
| **F. 记忆间关系链接** | 中 | 中 | 显式 `related-to`/`supersedes` 关系，L4 之外加一层记忆间引用 |
| **G. B7 全局 MCM_ 前缀** | 低 | 低（宽改动） | 裸全局变量加 `MCM_` 前缀防用户 env 碰撞。机械重命名 ~50 处，收益薄 |
| **H. 异步浓缩 worker** | 高 | 高 | ARCHITECTURE_V3.md A2 项；占位 chunk 自动浓缩。破坏"纯 Bash 零运行时依赖"主干，不建议 |

**建议下一步**：本文件描述的 **ledger（Phase 6）** 优先级最高——直接服务项目使命"AI 上下文跨会话存活"，且与主干（op-log 格式、event-sourcing、kill-switch）高度同构，风险低。

---

## 10. 验收标准

- [ ] `mcmLedger add/list/resolve/show` 四个子命令可用，`--json` 输出有效。
- [ ] `ledger.md` 格式与 op-log 同构，`grep '^## \[' ledger.md` 出时间线。
- [ ] SessionStart 注入最近 open todo/blocker，受 STOP/pause/MCM_LEDGER_INJECT 控制。
- [ ] resolve 不编辑原条目（sha256 不变），list 的 open 集正确收缩。
- [ ] op-log + NDJSON 事件接入。
- [ ] `test_phase6.sh` 全绿，总断言数 172 → ~190。
- [ ] 三连跑无 flake（沿用 v3.5 的惰性求值基线）。
- [ ] CLAUDE.md/README.md/SKILL.md 同步 v3.6。
