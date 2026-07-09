# 实现计划: Git 远程记忆共享 (Phase 7)

**日期**: 2026-07-09
**对应设计**: `docs/superpowers/specs/2026-07-09-git-remote-memory-sync-design.md`
**目标版本**: mcMemory v4.0 (Phase 7)
**当前基线**: v3.6 / 209 断言全绿

## 概述

为 mcMemory 增加 git 远程共享:`$MEMORY_BASE` 单仓库,手动 `mcmPush`/`mcmPull`,SessionStart opt-in ff-only auto-pull,L4 改 device-keyed JSON registry(弃软链),`.gitattributes` 给 append-only 日志标 `merge=union`,派生文件(`index.md`/`.search_index`/`hash.json`)gitignore + pull 后重建。

## 阶段依赖

```
7.1 device id + L4 重构 ──┐
                         ├─► 7.2 git 基础设施 + 派生重建 ──► 7.3 push/pull ──► 7.4 auto-pull ──► 7.5 测试+文档
                         └──────────────────────────────────────▲(L4 被同步)
```

- 7.1 先行:纯本地重构,不依赖 git,可独立回归测试。改动现有 L4 行为,**风险最高**,放最前以隔离。
- 7.2 依赖 7.1 的 device id(`mcmRemote init` 盖戳 `.device`)。
- 7.3 依赖 7.2 的 gitignore/重建机制。
- 7.4 依赖 7.3 的 pull。
- 7.5 收口。

---

## Phase 7.1 — device id + L4 device-keyed 重构

**目标**: 弃用 L4 软链,改为 `.claude/l4/<device>.json` per-device registry;新增 `current_device_id()`。本阶段不碰 git。

### 文件

| 文件 | 动作 |
|------|------|
| `lib/core.sh` | 改 `create_l4_link()`(~510)-> `record_l4_source()`;改 L4 读取点(~480-490,`*.source`/软链分支)-> `resolve_l4_source()`;新增 `current_device_id()`;新增 `record_l4_source()`/`resolve_l4_source()` |
| `commands/init.sh` | `create_l4_link` 调用点 -> `record_l4_source` |
| `commands/sync.sh` | 同上 |
| 其他 L4 读路径 | grep `create_l4_link` / `\.source` / `ln -s` 全仓,逐一改 |

### 函数

- `current_device_id()`:三级解析 `MCM_DEVICE` -> `$MEMORY_BASE/.device` -> `$(hostname)`。纯读,无副作用。
- `record_l4_source(memory_path, source_file)`:
  - 算 `rel_path = calculate_relative_path "$memory_path/.claude" "$source_file"`(复用现有)。
  - `device = current_device_id`。
  - 读/建 `$memory_path/.claude/l4/<device>.json`,结构 `{"device": <d>, "sources": {<basename>: <rel_path>}}`;用 `$PYTHON` 经 `sys.argv` 写(遵循 v2.0 注入安全规范)。
  - 幂等:同 basename 覆盖。
- `resolve_l4_source(memory_path, source_file)`:
  - 读 `$memory_path/.claude/l4/<current_device>.json` 的 `sources[<basename>]`;文件/键缺失返回空。
- **删除** `.source` 降级分支与 `ln -s` 调用(软链彻底下线)。

### 步骤

1. grep 全仓 L4 相关引用,列清单确认无隐藏读路径。
2. 加 `current_device_id()`(hostname 回退,本阶段 `.device` 尚不存在也能跑)。
3. 加 `record_l4_source`/`resolve_l4_source`。
4. 改 `create_l4_link` -> `record_l4_source`(init.sh/sync.sh)。
5. 改 L4 读取点 -> `resolve_l4_source`。
6. 删软链/`.source` 死代码。

### 测试点 (`tests/test_core.sh` 增补,或新建 `test_phase7_l4.sh`)

- `current_device_id`:`MCM_DEVICE` 覆盖 > `.device` > hostname。
- `record_l4_source` 写 JSON 结构正确;幂等覆盖;多源文件多键。
- `resolve_l4_source` 命中/缺失返回空。
- 不同 device 写不同文件互不干扰。
- **回归**: 现有 init/sync 生成 L4 后 `mcmLoad` 能读到(行为不变)。

### 验收

- `grep -rE 'ln -s|\.source|create_l4_link' lib/ commands/` 仅剩注释/历史。
- 现有 209 断言不回归 + 新增 ~8 断言。

---

## Phase 7.2 — git 基础设施 + 派生重建

**目标**: `mcmRemote init` 建 git 仓库 + 配置文件 + device 盖戳;抽取 `generate_l2_index`;新增 `rebuild_derived()`。

### 文件

| 文件 | 动作 |
|------|------|
| `commands/remote.sh` | 新建:`mcmRemote init/add/list/remove/device` |
| `lib/core.sh` | 抽 `generate_l2_index(memory_path)` from `init.sh:100-129`;加 `rebuild_derived()` |
| `commands/init.sh` | L2 生成改调 `generate_l2_index`(去重) |
| 命令分发器 | 注册 `mcmRemote`(`mcm_run_command` 所在处,grep 定位) |

### `mcmRemote` 子命令

- `init [--remote <url>] [--device <name>]`:
  - 前置检查 `git --version`;无则报错。
  - `[ -d .git ]` 则跳过 `git init`(幂等),仅补 `.gitignore`/`.gitattributes`。
  - 写 `.gitignore`/`.gitattributes`(spec §3 全文,heredoc)。
  - `.device` 不存在则写 `--device` 或 `$(hostname)`。
  - `git add -A` + `git commit -m "mcm: init remote store"`(空仓时跳过 commit)。
  - `--remote <url>`: `git remote add origin <url>` + `git push -u origin main`。
  - `acquire_lock` + `emit_event remote.init` + `log_memory_op`。
- `add <name> <url>` / `list` / `remove <name>`:透传 `git remote`。
- `device show`:打印 `current_device_id()` + 来源。
- `device set <name>`:`echo <name> > $MEMORY_BASE/.device`。

### `generate_l2_index(memory_path)`

- 从 `init.sh:100-129` 抽出,参数化 `memory_path`/`index_path`。
- init.sh 与 `rebuild_derived` 共用。
- 保留 tags 硬编码 `[general]`(已知限制,不改)。

### `rebuild_derived()`

- 遍历所有记忆目录(复用 `find_project_memory_dir`/list 枚举逻辑,grep 定位现有枚举)。
- 每记忆 `generate_l2_index`。
- `rebuild_search_index()`(已存在 core.sh:1079)。
- `hash.json` 不主动建(下次 `mcmSync` 补)。

### 测试点 (`test_phase7_infra.sh` 新建)

- `mcmRemote init` 在 fixture MEMORY_BASE 产生 `.git`/`.gitignore`/`.gitattributes`/`.device`。
- 幂等:二次 init 不破坏。
- `.gitignore` 正确忽略派生/本地态;**不忽略** `.claude/l4/`(验证 `git check-ignore` 取反生效)。
- `.gitattributes` 含 `log.md merge=union` 等。
- `generate_l2_index` 输出与原 init 一致(回归)。
- `rebuild_derived` 重建 index.md/search_index。

### 验收

- `mcmRemote init` 后 `git status` 干净(派生文件被 ignore)。
- 现有断言不回归 + 新增 ~10 断言。

---

## Phase 7.3 — mcmPush / mcmPull + 冲突 UX

**目标**: 推送/拉取命令,append-only union 合并,改写式冲突不静默。

### 文件

| 文件 | 动作 |
|------|------|
| `commands/push.sh` | 新建 |
| `commands/pull.sh` | 新建 |
| 命令分发器 | 注册 `mcmPush`/`mcmPull` |

### `mcmPush [--remote <name>] [--all] [--message <msg>]`

1. `acquire_lock`;检查至少一个 remote(`git remote`),无则报错。
2. `git add -A`。
3. 无 staged 变更 -> "无变更" exit 0。
4. commit message: `git diff --cached --name-only` 归约记忆名(`projects/<tag>/<name>/...` -> `<tag>/<name>`;`global/<mode>/<name>/...` -> `[global]<name>`),格式 `mcm: sync <n1>, <n2>`;`--message` 覆盖。
5. `git commit`;`log_memory_op push`;`emit_event push`。
6. push:默认 `origin`;`--remote <name>`;`--all` 遍历。单 remote 失败不阻断其他;汇总失败;exit code 反映。

### `mcmPull [--remote <name>] [--abort|--ours|--theirs <file>|--continue]`

1. `acquire_lock`。
2. 工作区脏(`git status --porcelain` 非空)且非 `--continue` -> 拒绝,提示 commit/stash。
3. `--abort` -> `git merge --abort`;`--ours/--theirs <file>` -> `git checkout --ours/--theirs <file>` + `git add`;`--continue` -> `git commit`(完成合并)。
4. 默认:`git fetch <remote>` + `git merge --no-edit <remote>/main`。
5. 成功 -> `rebuild_derived`;`log_memory_op pull`;`emit_event pull`。
6. 冲突(git 非 0) -> 打印冲突文件清单 + 引导(spec §6.2),不 abort,exit 非 0。

### 测试点 (`test_phase7_pushpull.sh` 新建)

- init->push->clone(tmp dir 作第二机)->pull 全链路,内容一致。
- 两机并发追加 `log.md` -> pull 无冲突(union),两边行都在。
- 两机并发追加 `ledger.md` -> 同上。
- 两机并发改 `summary.md` -> pull 报冲突,不静默丢;`--ours`/`--theirs`/`--continue`/`--abort` 各路径。
- 两设备并发写各自 `.claude/l4/<device>.json` -> pull 无冲突。
- `mcmPush` 无 remote 报错;`--all` 多 remote;commit message 归约正确。
- `mcmPull` 工作区脏拒绝。

### 验收

- 双机 round-trip 真记忆一致;派生文件 pull 后重建。
- 现有断言不回归 + 新增 ~15 断言。

---

## Phase 7.4 — SessionStart auto-pull (opt-in)

**目标**: `MCM_AUTOPULL=1` 时 SessionStart ff-only pull,尊重 STOP/pause,绝不阻塞。

### 文件

| 文件 | 动作 |
|------|------|
| `lib/inject.sh` | `session_start_inject` 末尾追加 auto-pull 块 |

### 逻辑

在 `session_start_inject` 加载 L1+auto L3(+ ledger 注入)之后追加:

```bash
if [[ "${MCM_AUTOPULL:-0}" == "1" ]] && ! is_stopped && ! is_inject_paused; then
    if git -C "$MEMORY_BASE" pull --ff-only origin main >/dev/null 2>&1; then
        log "auto-pull: fast-forwarded"
        emit_event autoppull.ok
    else
        log "auto-pull: 非快进或失败,请手动 mcmPull"
        emit_event autoppull.skip
    fi
fi
```

- 复用 `is_stopped`(v3.2)/`is_inject_paused`(v2.4),与 ledger 注入一致(不走 BM25/cooldown)。
- `--ff-only`:落后可 ff 则前进;否则静默跳过,不产生 merge、不阻塞会话。
- `.stop`/`.paused` 存在则整段跳过。

### 测试点 (`test_phase7_autopull.sh` 新建)

- `MCM_AUTOPULL=1` + 落后可 ff -> fast-forward,记忆更新。
- 落后不可 ff(本地有新 commit)-> 跳过,不报错不阻塞,emit `autoppull.skip`。
- `.stop` 存在 -> 跳过(即使 MCM_AUTOPULL=1)。
- `.paused` 存在 -> 跳过。
- 默认 off(`MCM_AUTOPULL` 未设)-> 不执行。

### 验收

- auto-pull 永不阻塞会话、永不产生 merge commit。
- 现有断言不回归 + 新增 ~5 断言。

---

## Phase 7.5 — 集成测试 + 文档同步

**目标**: 端到端集成 + 文档对齐 v4.0。

### 集成测试 (`tests/integration/test_remote_e2e.sh` 新建)

- 完整剧本:机 A `mcmRemote init` -> 写记忆 -> `mcmPush`;机 B clone -> `mcmDoctor` 重建 -> `mcmInit --name` 绑定 + 写本机 L4 -> `mcmPull` -> 双向 round-trip。
- 并发:两机同时 `mcmPush` 后互 `mcmPull`,union 文件无冲突、改写文件冲突正确报。
- auto-pull e2e:机 B SessionStart 拉到机 A 新记忆。
- L4 device:两设备各自 L4 文件独立,互不覆盖。

### 文档同步

- `CLAUDE.md`:加 v4.0 Phase 7 段(命令表加 mcmRemote/mcmPush/mcmPull;新增 device/L4 重构/gitignore 分类说明)。
- `README.md` / `SKILL.md`:命令表与引导章节同步;SKILL.md 加远程共享用法。
- 命令速查表加新命令。

### 验收

- 三连跑全绿;总断言 209 -> ~247(+~38)。
- `mcmStatus --drift` 无新增 broken/orphan(L4 重构无残留旧软链)。
- `grep -rE 'ln -s|create_l4_link|\.source' lib/ commands/` 无功能代码(仅注释/历史)。

---

## 风险与回归

| 风险 | 缓解 |
|------|------|
| L4 重构漏改隐藏读路径 | 7.1 步骤 1 grep 全仓;回归 `mcmLoad` L4 |
| `.gitignore` `index.md` 误伤需跟踪文件 | 7.2 测试 `git check-ignore` 取反;index.md 均派生(已确认 init.sh:100-129) |
| `.claude/*` + `!.claude/l4/` 否定模式在老 git 失效 | 要求 git ≥ 2.x(普遍);测试验证 `l4/` 可跟踪 |
| L4 JSON 同 basename 源文件冲突 | 与现有 L4 行为一致(按 basename),非回归;若需修另开 issue |
| auto-pull 在无 remote/无网络环境报错噪声 | `2>/dev/null` + skip log;不阻断 |
| device hostname 撞名 | `mcmRemote device set`;文档化 |

## 实现顺序速查

1. **7.1** L4 + device id(本地重构,最高风险先隔离)
2. **7.2** mcmRemote init + generate_l2_index/rebuild_derived
3. **7.3** mcmPush / mcmPull + 冲突 UX
4. **7.4** SessionStart auto-pull
5. **7.5** e2e 集成 + 文档

每阶段结束跑全量测试 + 三连跑验证无 flake(沿用项目惯例)。
