# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

mcMemory (mcm) is a Claude Code skill that implements a hierarchical memory management system in pure Bash (v4.0). It persists project and personal knowledge to `~/.claude/mcMemories/` so AI context survives across sessions, and shares memories across machines/teams via git (v4.0 Phase 7).

## v4.0 fixes (2026-07-09) - git 远程记忆共享（Phase 7）

- **git 远程共享**: `$MEMORY_BASE` 整体作为单一 git 仓库，手动 `mcmPush`/`mcmPull` 同步；SessionStart opt-in `MCM_AUTOPULL=1` 走 `git pull --ff-only`（永不阻塞会话，落后不可快进则静默跳过），尊重 STOP/pause kill-switch。团队可信场景下团队 remote 接收完整 repo（无需 subtree）。
- **L4 device-keyed registry（弃用软链）**: L4 源文件引用从 `.claude/` 软链改为 `.claude/l4/<device>.json`，每设备一文件记录源文件相对路径。`current_device_id()` 三级解析：`MCM_DEVICE` env > `$MEMORY_BASE/.device` > `hostname`。新增 `record_l4_source`/`resolve_l4_source`；`check_l4_health` 改读 JSON 判 valid/broken（输出契约 `"valid broken copy"` 不变，copy 恒 0）。每设备独立文件 -> git 合并零冲突；弃用软链 -> 跨平台无碍。
- **派生/本地态分离（.gitignore）**: 派生文件 `.search_index`/`index.md`(各层)/`hash.json` 与机器本地态 `.locks/`/`.inject_state/`/`.inject_log`/`.trash/`/`.events.ndjson`/`.session_log.md`/`.device`/`.workspace`/`.claude/`(除 `l4/`)全部 gitignore；pull/clone 后 `rebuild_derived()` 重建 `.search_index` + 缺失 `index.md`（从 chunks frontmatter 重建），`mcmDoctor` 在 `.search_index` 缺失时自动触发。
- **`.gitattributes` 零冲突合并**: `log.md`/`ledger.md` 标 `merge=union`（append-only 取两边不打冲突标记），`* text=auto eol=lf` 防跨平台 CRLF。
- **新增命令**: `mcmRemote init/add/list/remove/device`、`mcmPush [--remote/--all/--message]`（commit + push，识别未推送 merge commit 而非仅 staged 变更）、`mcmPull [--abort/--ours/--theirs/--continue]`（fetch+merge，改写式冲突不静默）。
- **冲突策略**: `summary.md`/`chunks` 改写式冲突人工裁定；`log.md`/`ledger.md`/`l4/<device>.json` 经 union/per-device 机制自动无冲突合并。
- 测试: 新增 `test_phase7_l4.sh`(27)/`test_phase7_remote.sh`(27)/`test_phase7_pushpull.sh`(26)/`test_phase7_autopull.sh`(6)/`test_remote_e2e.sh`(11)，总断言 209 -> 306。三连跑全绿。

## v3.6 fixes (2026-07-05) — 会话决策日志（Session Ledger，Phase 6）

- **Ledger 结构化决策日志**: 每个记忆目录新增 `<memory>/ledger.md`，append-only、不可变、grep 友好。复用 op-log 的 `## [ts] type (actor)` 格式，扩展 `status:`/`resolves:`/`refs:`/`context:` 字段。
- **`mcmLedger` 命令**: `add` / `list` / `resolve` / `show` 四个子命令，支持 `--type` / `--status` / `--since` / `--limit` / `--json` 过滤。`add` 可省略子命令名（`mcmLedger todo "修 X"`）。`resolve` 追加 `done` 条目并带 `resolves:` 引用，不编辑原条目（event-sourcing 语义）。
- **SessionStart 自动注入未竟事项**: `session_start_inject` 在加载 L1 + auto L3 后，追加最近 N 条 open todo/blocker。受 `MCM_LEDGER_INJECT`（默认 1）/ `MCM_LEDGER_INJECT_COUNT`（默认 5）/ `MCM_LEDGER_INJECT_TYPES` / `MCM_LEDGER_INJECT_SINCE_DAYS` 控制。尊重 STOP/pause kill-switch，不走 BM25/cooldown 路径。
- **op-log + NDJSON 事件接入**: `ledger.add` / `ledger.resolve` 事件写入 `.events.ndjson`，`log.md` 记录 `ledger` 操作。
- **纯 Bash + 内联 Python**: `lib/ledger.sh` 提供解析/过滤/注入函数，`ledger_parse` / `ledger_open_entries` / `ledger_list` 均用单次 Python 调用，复杂度 O(n)。
- 测试: 新增 `test_phase6.sh`（37 断言），总断言数 172 → 209。三连跑全绿。

## v3.5 fixes (2026-07-04) — inject.sh 常量惰性求值（Phase 5）

- **根因修复 inject.sh 模块级常量冻结**: 旧实现在 source 时算定 `INJECT_STATE_DIR`/`INJECT_PAUSE_FILE`/`INJECT_STOP_FILE`（并 `mkdir -p` 副作用），调用方后改 `$MEMORY_BASE` 时（集成测试换 fixture、多 base 部署），常量仍指向旧值 → cooldown/pause/stop 写错地方，引发静默失败与跨运行 120s 内 flake（v3.4 phase4 journal 测试即踩此坑，v3.2 phase2 STOP 测试也有同源 workaround）。现各函数内联 `"${MEMORY_BASE:-$HOME/.claude/mcMemories}/<file>"` 在调用时读取现行值；`mkdir` 副作用移到 `mark_injected` 写时建。
- **移除两处测试 workaround**: phase2 STOP 测试与 phase4 journal 测试不再需要"it_setup 后重 source inject.sh"——根因已修，三连跑全绿。
- **inject-log.sh 解耦**: 不再 source inject.sh（它原本只为拿已下线的 `INJECT_PAUSE_FILE` 常量），pause 路径内联惰性。
- **副作用收益**: source inject.sh 不再在 `$HOME/.claude/mcMemories/.inject_state` 建空目录（消除测试对真实 HOME 的污染）。
- 测试: 仍 172 项（无新增断言，三连跑验证 flake 根除）。

## v3.4 fixes (2026-07-04) — 搜索评分排序 + 命令覆盖（Phase 4）

- **mcmSearch --score**: 新增 `--score` 开关，按 BM25×source×evidence 权重排序结果并显示分数。复用 `find_relevant_memories` 评分管线（pass `MAX_INJECT_MEMORIES=9999` 取全部），候选 chunk 仍按子串匹配收集（保持召回语义），仅排序/展示改为评分。opt-in：不开 `--score` 时行为与 v3.3 完全一致（零回归）。`--score --json` 输出含 `score` 字段。顺手补 `--scope` 解析（`user`→`global`）。
- **命令集成测试覆盖**: 新增 `test_phase4.sh`（24 断言）补 8 个无专门集成测试的命令：mcmSearch（召回/--expand/--json/--global/--score 排序）、mcmUpdate --tags（标签迁移物理移动目录）、delete→restore→empty-trash 完整回收站生命周期、mcmLoad（L1/L3）、mcmJournal + mcmInjectLog（注入事件解析）。
- **修 inject.sh 常量冻结的测试 flake**: `it_journal_and_inject_log` 在 it_setup 后重 source inject.sh，让 `INJECT_STATE_DIR` 等指向 fixture（旧实现指向 `$HOME` → cooldown 跨运行 120s 内误判 jourproj 冷却而跳过注入 → 事件不发出）。与 v3.2 phase2 STOP 测试同一潜藏设计问题，本测试沿用其 workaround。
- 测试: +24 断言，总计 172 项。

## v3.3 fixes (2026-07-04) — 评分制 + 证据分层（Phase 3）

- **drift 评分制 (mex 风格)**: `mcmStatus --drift` 从清单升级为 100 点评分。每个记忆独立打分，扣分项：broken L4 ×8 / orphan chunk ×8 / 陈旧 chunk ×4 / 索引缺失 ×4 / 占位 chunk ×2。等级 A(≥95) B(≥80) C(≥60) D(≥40) F(<40)。新增**索引缺失**信号（chunk 存在但未被 `$SEARCH_INDEX` 收录 → 搜索召回不到，比 orphan 更隐蔽）。`--drift --json` 输出 per-memory 分数 + issues 数组。修了 v3.2 雏形的 subshell 陷阱（helper 在 `$(...)` 内 `issues+=` 失效 → 改走临时文件传递）。
- **证据/来源分层 (eidetic 风格)**: chunk frontmatter 新增 `source` (user=1.0/agent=0.7/system=0.5) + `evidence` (validated=1.0/observed=0.85/hypothesis=0.6) 字段。搜索索引每个 section header 后插 `<!-- mcm-meta source=X evidence=Y -->` 元数据行。`find_relevant_memories` 解析后 `final_score = bm25 × max_weight`（per memory 取 best evidence wins），缺省 agent×observed=0.595 折扣防幻觉。`source:agent` 自引用默认折扣，user/validated 提升至 1.0。旧索引（无 meta 行）按缺省 0.595 处理，向后兼容。
- **mcmMark 命令**: `mcmMark <名称> [--chunk <名>] [--source ...] [--evidence ...] [--global]` 人工标注 chunk 来源/证据等级，批量改 frontmatter + 重建索引段 + op-log。防幻觉的核心杠杆：已验证知识提升权重，猜测性内容降级。
- 测试: +16 断言（drift 评分/索引缺失/meta 行/权重排序/mcmMark/向后兼容六组），总计 148 项。

## v3.2 fixes (2026-07-04) — 可观测性补全（Phase 2）

- **op-log 记忆级操作日志**: `log_memory_op()` 追加 `## [ISO8601] op (actor)` 到 `<memory>/log.md`；init/sync/update/delete/restore/import/inject/precompact 8 个写操作接入。`grep '^## \[' log.md` 即时间线。与 NDJSON 事件总线（命令级）互补：op-log 按记忆隔离、grep 友好。
- **全局 STOP kill-switch**: `~/.claude/mcMemories/.stop` 存在则 session_start/prompt_submit 无条件跳过注入（emit `inject.stopped`）。`mcmAutoInject stop`/`unstop` 子命令。与 pause（带时长自动恢复）互补：STOP 需显式取消。
- **mcmStatus --drift 雏形**: 报告 broken L4 链接 / 陈旧 chunk（mtime > `MCM_DRIFT_STALE_DAYS` 天，默认 30）/ 孤儿 chunk（source_file 已删）。仅清单不评分（评分制留 Phase 3）。排除 `.canary/` 探针。
- **doctor canary 端到端验证**: `mcmDoctor` 在 `$GLOBAL_DIR/.canary/` 隐藏 dotdir 放含唯一 token 的探针记忆，跑 `find_relevant_memories` 断言命中——验证搜索管线真的可用（而非仅文件存在）。canary 不入 index.md 且 dotdir 被 `*/` 跳过，不污染 mcmList/mcmStatus。
- **顺手修复 restore 潜在 bug**: 旧代码在 `restore_from_trash`（内部已 `rm .origin`）之后才读 `.origin` → 搜索索引更新被静默跳过。改为提前取 origin_path。
- 测试: +15 断言（op-log/STOP/drift/canary 四组集成测试），总计 132 项。

## v3.1 fixes (2026-07-04) — 当前状态

- **B2 (CRITICAL, 数据完整性)**: `find_project_memory_dir` 旧实现只用 `basename(git toplevel)` 推名字，忽略 `mcmInit --name`，导致自定义命名项目的 `mcmSync`/`precompact_save`/`session_start_inject` 找不到记忆目录而静默失败（PreCompact 失败时 session_notes.md 不清空，会话笔记可能丢失）。修复：查找顺序改为 ① 显式 name 直查 → ② `.workspace` 标记扫描（`mcmInit` 时记录 workspace origin）→ ③ basename 回退（兼容旧记忆）。`mcmInit` 写 `$memory_path/.workspace`；`mcmSync` 透传 `--name`。
- **B5 (HIGH, 评分一致性)**: `prompt_submit_inject` 旧实现在 `find_relevant_memories` 已 BM25 排序后又用 `grep -iqF` 重算 0/3/1 分（门槛 2），丢弃了 BM25 score，两套评分叠加会漂移。修复：`find_relevant_memories` 输出 `name<TAB>score`，`prompt_submit` 直接用 BM25 score 过 `INJECT_BM25_MIN_SCORE` 门槛（默认 0），下线 grep 二次打分。
- **死代码清理**: 删除无调用方的 `find_project_tag()`（与 B2 同区域）。
- **文档同步**: CLAUDE.md/README.md/SKILL.md 从 v2.3/48 断言同步到 v3.1/117 断言。

## v3.0 fixes (2026-07-04) — 事件总线 + 集成测试地基

- **NDJSON 事件总线** (`lib/events.sh`): `emit_event` 单行原子追加 `.events.ndjson`；`mcm_on_exit` 链式 trap 注册（兼容已有锁释放）；`mcm_run_command` 包裹 16 个命令的 `cmd.start`/`cmd.end`（带 `duration_ms`/`exit`），3 个 hooks emit `hook.invoke`/`hook.complete`。
- **集成测试套件**: `tests/integration/` 新增 `test_hook_e2e.sh`（5 it，hook 端到端 + 中文 BM25 召回）、`test_sync_idempotent.sh`（含 B2 回归）、`test_concurrent.sh`（10 并发 sync 无损坏 + inject 期间不撕裂）。
- 配置: `MCM_EVENTS_FILE` / `MCM_EVENTS_MAX_BYTES`（默认 1MB，超限 `tail -n 2000` 截尾）。

## v2.4 fixes (2026-06-09)

- **BM25 评分**: `find_relevant_memories` 标准 BM25 (k1=1.2, b=0.75) + Robertson IDF + 长度归一化，替换旧 sqrt(n) 归一化；header 命中 ×3，性能 ~10s → <100ms。
- **中文关键词**: `extract_keywords` 抓连续汉字段 + 2-gram bigram + 中英停用词表，修复中文零召回 bug。
- **pause 开关**: `is_inject_paused` 检查 `.paused_until` 时间戳；`mcmAutoInject pause 30m/2h/1d`。
- **新命令**: `mcmInjectLog`（注入事件日志）、`mcmJournal`（一行会话笔记）、`mcmDoctor`（健康检查 + 脏 tag 迁移 + 占位 chunk 报告）。
- **搜索索引原子写**: `rebuild`/`remove`/`update` 走 tmp+mv，消除 TOCTOU；集成测试验证 10 并发无撕裂。
- **占位 chunk 跳过**: `is_placeholder_chunk` 在注入和 session_start 都跳过 `[待AI补充` chunk。
- 测试: 63 单元 + 33 集成断言。

## v2.3 fixes (2026-06-08)

- **CRITICAL**: `acquire_lock()` flock fd 分配改用 bash `exec {fd}` 自动分配，消除 RANDOM 碰撞和 eval 注入风险。token 格式从 `123` 改为 `flock:FD:FILE`。
- **HIGH**: `get_project_tags()` / `get_global_modes()` 用 `for` 循环替代 `| while`，消除 subshell 使 `local` 生效，移除 `ls` 依赖。
- **HIGH**: `split_source_file()` 用数组收集行替代 O(n²) 字符串拼接，3301 行文件拆分 300 chunks 仅 0.1s。
- **HIGH**: `sed_escape()` 改用纯 `sed` 替代 Python，修复原 bash 实现中 `?`/`*` 被当作 glob 通配符的隐藏 bug。
- **HIGH**: `mcmSearch` index 快速路径统一返回 chunk 文件路径，`--json`/`--expand` 在所有路径下正常工作。
- **MEDIUM**: `generate_summary_md()` 纯输出到 stdout，移除文件 I/O 副作用。
- **MEDIUM**: `build_hash_json` 的 `mtime` 统一为 ISO 8601 字符串格式（与 `get_mtime()` 一致）。
- **MEDIUM**: `batch_update_chunk_frontmatter()` — 单次 Python 批量更新所有 chunk frontmatter，sync 10 文件从 20 次 Python 降到 2 次。
- **MEDIUM**: `mcmUpdate` 在目录移动/重命名后正确更新搜索索引。
- **LOW**: `mcmSync` 无变化时跳过冗余的索引更新。
- **LOW**: 错误消息统一为中文。
- 测试: 48 项断言全部通过。

## v2.2 fixes (2026-06-04)

- **PreCompact 真正会话压缩**: `precompact_save()` 读取 AI 写入的 `.claude/session_notes.md`，生成带时间戳的 L3 chunk (`chunks/session_*.md`)，增量更新搜索索引，清空源文件。SKILL.md 新增会话笔记写入指令。
- **增量搜索索引**: 新增 `update_search_index()` / `remove_from_search_index()` / `append_to_search_index()`，7 处调用点从 O(all_chunks) 全量重建改为 O(memory_chunks) 增量更新。
- **消除双次 split**: `step3_generate_chunks` 缓存 `split_source_file` 输出到数组，第二遍从缓存重放。
- **search.sh scope 过滤**: 索引快速路径通过 awk section 跟踪正确过滤 `--global` 结果。
- **删除 4 个死函数**: `write_hash_json`, `search_index`, `get_line_range`, `read_chunk_segment`。
- **新增测试**: `test_acquire_release_lock`, `test_move_and_restore_trash`，总计 41 个断言。

## v2.1 fixes (2026-04-27)

- **CRITICAL**: `auto-inject.sh` hook_config heredoc was single-quoted, preventing `$SKILL_DIR` expansion. Fixed to unquoted heredoc with proper nested hooks format (`hooks: [{type: "command", command: "..."}]`).
- **HIGH**: `inject.sh` find_relevant_memories only searched delimiter headers, never chunk content. Rewritten to scan full index content with keyword matching.
- **HIGH**: `inject.sh` grep missing `-F` flag for fixed-string matching. Added `-F` to both find_relevant_memories and prompt_submit_inject.
- **HIGH**: `inject.sh` session_start_inject now marks global auto memories as injected (cooldown) and fixes multi-line summary prefix.
- **MEDIUM**: `core.sh` generate_summary_md now accepts explicit `memory_path` parameter instead of relying on caller dynamic scoping.
- **MEDIUM**: `core.sh` sed_escape rewritten using Python `re.escape` for complete regex metacharacter handling.
- **MEDIUM**: `init.sh` now creates a minimal L3 chunk for global memories without source files, ensuring search index and inject hooks have content to work with.
- `auto-inject.sh` merge_hooks_json and remove_hooks_json updated to handle both old flat format and new nested hooks format.

## Architecture

```
SKILL.md                  ← Claude Code skill manifest (name, allowed-tools, description)
lib/core.sh               ← Shared library sourced by every command
commands/*.sh             ← One script per CLI command, each follows the same pattern
tests/test_core.sh        ← Unit tests (bats-compatible, run: bash tests/test_core.sh)
```

**Data is stored outside the skill directory** at `$MEMORY_BASE` (default `~/.claude/mcMemories/`).

### Execution model

Each command script:
1. Sources `lib/core.sh` via `source "$(dirname "$0")/../lib/core.sh"`
2. Parses args in `parse_args()`
3. Runs numbered step functions (`step1_...`, `step2_...`, etc.)
4. Has a `main()` that orchestrates the flow
5. `set -e` aborts on any failing command

### Four-layer memory model

| Layer | What | Where |
|-------|------|-------|
| L1 | Project name + description | `summary.md` |
| L2 | Outline index: title, tags, summary, line ranges | `index.md` |
| L3 | AI-condensed chunks with YAML frontmatter | `chunks/*.md` |
| L4 | References to original source files (project only, device-keyed) | `.claude/l4/<device>.json` (v4.0) |

## Key v2.0 design points

### hash.json uses workspace-relative paths

`build_hash_json "$workspace" file1 file2...` produces `{ "path/to/file.md": { "hash": "...", "mtime": "..." } }` — keys are relative to workspace, not basenames. `read_hash_keys` and `read_hash_value` use `sys.argv` (not string interpolation) for safe parameter passing.

### Dynamic tag discovery

Tags are no longer hardcoded. `get_project_tags()` and `get_global_modes()` discover tags by listing subdirectories. `find_memory_path()` and `find_project_memory_dir()` iterate discovered tags dynamically. A user can run `mcmInit --tags "mobile"` and the new tag is automatically usable.

### Concurrency protection

Write operations (`init`, `sync`, `delete`, `update`, `restore`) acquire a lock before mutating state. `acquire_lock()` tries `flock` first, falls back to `mkdir` atomicity. `release_lock()` cleans up. The `trap ... EXIT` pattern ensures locks are released on error.

### Trash instead of permanent delete

`mcmDelete` moves to `$TRASH_DIR` with a `.origin` marker file recording the original path. `mcmRestore` reads the origin and moves the directory back. `mcmEmptyTrash` permanently removes trash contents.

### Python calls use sys.argv (not string interpolation)

All `$PYTHON -c "..."` calls in v2.0 pass file paths through `sys.argv` instead of inline string interpolation, eliminating injection risk from special characters in paths. Example: `$PYTHON -c "open(sys.argv[1])" "$file"`

### L4 device-keyed source registry (v4.0)
`record_l4_source()` records each source file's relative path (via `calculate_relative_path()`, from the `.claude/` dir) into `.claude/l4/<device>.json`, keyed by `current_device_id()` (`MCM_DEVICE` env > `.device` > hostname). Each device writes its own file, so multi-machine git sync merges without conflict. Symlinks/`.source` removed; cross-platform clean. `check_l4_health()` reads the JSON to count valid/broken targets.
`create_l4_link()` computes the relative path from the `.claude/` dir to the source file using `calculate_relative_path()`, which normalizes separators to `/`. Symlinks and `.source` files both store relative paths, surviving project directory relocation.

### Large file auto-splitting

`split_source_file()` in core.sh splits source files exceeding `$CHUNK_SPLIT_THRESHOLD` (default 200 lines) on `##` markdown headings, creating multiple numbered chunks (e.g., `1_ARCHITECTURE_1.md`, `1_ARCHITECTURE_2.md`).

### Search index

`rebuild_search_index()` merges all chunks into a single `$SEARCH_INDEX` file with delimiter headers. `mcmSearch` prefers this index for O(1) file access instead of O(n) find+grep. Called at the end of `init`, `sync`, `delete`, and `restore`.

### Non-.md source files

`detect_source_files()` automatically detects `package.json`, `Makefile`, `docker-compose.yml`, `.env.example`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `CMakeLists.txt`. Users can extend via `$SOURCE_PATTERNS` env var.

## Commands reference

| Command | Purpose |
|---------|---------|
| `mcmInit` | Initialize project/global memory |
| `mcmSync` | Incremental sync (hash-driven) |
| `mcmLoad` | Load memory into session context |
| `mcmSearch` | Full-text search (uses search index) |
| `mcmList` | List all registered memories |
| `mcmStatus` | Health overview, freshness, trash status; `--drift` 100-point drift scoring (v3.3) |
| `mcmUpdate` | Update name/description/tags (tags now work) |
| `mcmDelete` | Move to trash |
| `mcmExport` | Export memory as tar.gz |
| `mcmImport` | Import from tar.gz archive |
| `mcmRestore` | Restore from trash |
| `mcmEmptyTrash` | Permanently empty trash |
| `mcmMark` | Mark chunk source/evidence → BM25 weight (v3.3) |
| `mcmLedger` | 会话决策日志：add/list/resolve/show 结构化决策/待办/阻断 (v3.6) |
| `mcmRemote` | git 远程共享：init/add/list/remove/device (v4.0) |
| `mcmPush` | 提交并推送记忆变更到 git remote (v4.0) |
| `mcmPull` | 拉取并合并，冲突不静默 (v4.0) |

Common flags: `--global`, `--json` (list/search/status/ledger), `--expand` (search), `--force` (delete/empty-trash). Env: `MCM_AUTOPULL` (SessionStart ff-only auto-pull), `MCM_DEVICE` (override device id).

## AI condensation flow (important)

After `mcmInit` or `mcmSync`, chunk files may contain `[待AI补充：浓缩内容]`. Claude should:
1. Read each chunk's `source_file` from its YAML frontmatter
2. Read the source file with the `Read` tool
3. Generate structured condensed content (10-30% of original, keeping key decisions/APIs/patterns)
4. Use `Edit` to replace the placeholder with actual content

Global memories with `auto` tag should be auto-loaded at session start via `mcmLoad --layer L3`.
