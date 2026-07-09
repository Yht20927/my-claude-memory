# Git 远程记忆共享 - 设计文档

**日期**: 2026-07-09
**状态**: Draft,待用户评审
**目标版本**: mcMemory v4.0 (Phase 7)

## 1. 目标与范围

用 git 作为中转,实现 mcMemory 记忆的远程共享:

- **场景 A - 多机个人同步**: 同一人在多台机器(笔记本/台式机/服务器)间同步自己的全部记忆。
- **场景 B - 团队共享项目记忆**: 多人共享某个项目的记忆;团队 remote 接收完整 repo,队友只关注 `projects/`。

### 已确定的设计取舍(经 brainstorming 确认)

| 决策点 | 选择 | 理由 |
|--------|------|------|
| 使用场景 | A + B 两者 | 个人走私有 remote,项目走团队 remote |
| git 拓扑 | 整个 `$MEMORY_BASE` 一个仓库 | 集中存储已如此,1 个 repo 最简 |
| 团队隐私 | 团队可信,可全推 | 无需 `git subtree`,团队路径也是普通 `git push` |
| 触发模型 | 手动 `mcmPush`/`mcmPull` + 可选 SessionStart 自动 pull | 记忆是慢变量,手动足够,冲突在可预期时机浮现 |
| L4 跨设备 | device-keyed registry(每设备一文件) | 源文件路径随设备而异,需按设备记录;同步而非忽略 |

### 不在范围内(显式 YAGNI)

- `git subtree` 严格隐私隔离(团队可信前提下不需要;若将来需要严格隔离,作为 v4.1 增量)
- 全自动 PostToolUse push(慢变量下收益低、风险高)
- 按记忆粒度路由到不同 remote(全推模型下退化为"推到哪个 remote")
- 双向实时同步/WebDAV/对象存储等其他后端
- 跨仓库的 cherry-pick / 精细 ACL
- device-keyed `.workspace`(单值标记,`mcmInit --name` 即可重绑,不值得加复杂度;仅 L4 走 device 机制)

## 2. 架构

### 2.1 仓库拓扑

`~/.claude/mcMemories/`(`$MEMORY_BASE`)整体 `git init` 成单一仓库,单分支 `main`。

```
~/.claude/mcMemories/          <- git repo root (.git/)
├── .gitignore
├── .gitattributes
├── .device                    <- 本机 device id(机器本地,gitignore)
├── global/
│   ├── index.md               <- registry(派生,gitignore)
│   └── <mode>/<name>/
│       ├── summary.md         <- L1(同步)
│       ├── index.md           <- L2(派生,gitignore)
│       ├── chunks/*.md        <- L3(同步)
│       ├── log.md             <- op-log(同步,union merge)
│       ├── ledger.md          <- 会话日志(同步,union merge)
│       └── hash.json          <- 派生(gitignore)
└── projects/
    ├── index.md               <- registry(派生,gitignore)
    └── <tag>/<name>/
        ├── summary.md / index.md / chunks/ / log.md / ledger.md
        ├── .workspace         <- 机器本地(gitignore)
        └── .claude/           <- L4 device registry(同步,见 §3.1)
            └── l4/<device>.json
```

**Remote 模型**: 复用 git 原生 remote,不另建配置。
- `origin` = 个人私有 remote(多机同步主通道)
- `<team-name>` = 团队 remote(任意个数,`mcmRemote add` 添加)

`mcmPush` 默认推 `origin`;`--remote <name>` 指定;`--all` 推所有 remote。

### 2.2 执行模型

新增命令遵循现有 commands/ 模式(source core.sh、parse_args、numbered steps、set -e、走 `acquire_lock`)。写操作复用 `log_memory_op()` 记 op-log,复用 `emit_event` 写 NDJSON 事件。git 操作不绕过既有锁。

## 3. 文件分类(核心)

| 文件 | 类别 | git 处理 | 依据 |
|------|------|----------|------|
| `chunks/*.md` | 真记忆(AI 编辑) | **同步** | 不可重建,核心内容 |
| `summary.md` | 真记忆(`mcmUpdate` 改写) | **同步** | 含人工设的 name/description |
| `log.md` | append-only op-log | **同步** + `merge=union` | 追加,union 取两边零冲突 |
| `ledger.md` | append-only 会话日志 | **同步** + `merge=union` | 同上(v3.6) |
| `.claude/l4/<device>.json` | 真记忆(device-keyed L4) | **同步** | 每设备一文件,记录该设备源文件路径(§3.1) |
| `index.md`(各层) | 派生 | **gitignore** | `init.sh:100-129` 从 chunks 生成骨架,pull 后重建 |
| `.search_index` | 派生 | **gitignore** | 从 chunks 重建(v2.2) |
| `**/hash.json` | 派生 | **gitignore** | `mcmSync` 重算(v2.0) |
| `.device` | 机器本地 | **gitignore** | 本机 device id |
| `.workspace` | 机器本地 | **gitignore** | 记录本机 workspace origin,路径机器相关(B2 basename 回退兜底) |
| `.session_log.md` | 机器本地 | **gitignore** | 会话日志,机器本地 |
| `.locks/` | 机器本地 | **gitignore** | flock 本机态 |
| `.inject_state/` | 机器本地 | **gitignore** | 冷却态 |
| `.inject_log` | 机器本地 | **gitignore** | 注入日志 |
| `.trash/` | 机器本地 | **gitignore** | 回收站 |
| `.events.ndjson` | 机器本地遥测 | **gitignore** | 有 rotation(`tail -n 2000`),union 合并会撕裂 |
| `.claude/`(除 `l4/` 外) | 机器本地 | **gitignore** | 运行时物化的软链等(若有);L4 已迁至 `l4/` |

### `.gitignore`

```gitignore
# 派生文件(pull 后由 mcmSync/doctor 重建)
.search_index
index.md
**/hash.json

# 机器本地态
.locks/
.inject_state/
.inject_log
.trash/
.events.ndjson
.session_log.md
.device
.workspace

# .claude/ 下仅 l4/ device registry 同步(§3.1),其余机器本地
.claude/*
!.claude/l4/
```

> 注: `index.md` 全局忽略会同时命中顶层 registry 与每记忆 L2(均为派生)。mcmPull 后需重建(见 §5)。
> 注: `.claude/*` + `!.claude/l4/` 的否定模式:排除 `.claude/` 下所有条目,仅重新纳入 `l4/` 目录及其内容。

### `.gitattributes`

```gitattributes
# append-only 日志:union 合并自动取两边,不打冲突标记
log.md      merge=union
ledger.md   merge=union

# 行尾统一,避免 CRLF 污染 frontmatter 解析(跨平台)
* text=auto eol=lf
```

`merge=union` 是让远程同步真正可用的关键:两台机器各自往 `log.md`/`ledger.md` 末尾追加,git 默认会在 EOF 撞冲突;union 策略直接拼接两边。`summary.md`/`chunks/*.md` 是改写式,不在 union 列表,冲突走 §6 人工解决。

## 3.1 L4 device 标记机制(替代软链)

### 动机

L4 是记忆到源文件的引用。源文件路径随设备而异(笔记本 `~/project/foo`,服务器 `/srv/foo`),旧实现用软链存相对路径,无法跨设备复用、且软链在 Windows 会断。改为 **device-keyed registry**:每设备一个文件,记录该设备的源文件路径,同步到 git。

### 设备标识 `current_device_id()`

三级解析:
1. `MCM_DEVICE` 环境变量(显式覆盖,最高优先)
2. `$MEMORY_BASE/.device` 文件(gitignored,持久化;`mcmRemote init` 首次运行时若不存在,以 `$(hostname)` 盖戳)
3. 回退 `$(hostname)`

### 存储

每记忆目录 `.claude/l4/<device>.json`,一设备一文件:

```json
{
  "device": "laptop-yang",
  "sources": {
    "CLAUDE.md": "../../../../../project/foo/CLAUDE.md",
    "src/main.py": "../../../../../project/foo/src/main.py"
  }
}
```

- 路径相对该记忆 `.claude/` 目录(复用现有 `calculate_relative_path()`)。
- **每设备独立文件** -> 不同设备并发写不撞同一文件 -> git 合并零冲突。
- 同步后团队可见各设备源文件布局(信息性);每设备运行时只用自己 device 的条目。

### API 重构(`lib/core.sh`)

- `create_l4_link()` → `record_l4_source(memory_path, source_file)`:算相对路径,写入 `.claude/l4/<current_device>.json` 的 `sources`(若文件不存在则创建,含 `device` 字段)。
- 新增 `resolve_l4_source(memory_path, source_file)`:读当前 device 的 `sources` 返回路径。
- 新增 `current_device_id()`:上述三级解析。
- 现有读 L4 的调用点(`core.sh:487` 一带读 `.source`/软链)改读 device JSON。
- **彻底弃用软链** -> Windows 跨平台问题消失,无需 `.source` 降级路径。

### 拉取后行为

L4 是真同步数据(非派生),pull 后**无需重建**。当前设备的 `<device>.json` 若已存在(本机之前推过),直接可用;若新机首次 clone,本设备条目尚无,需 `mcmInit`/`mcmSync` 探测源文件后写入(见 §9.2)。

### 设备冲突边缘

两台机器 hostname 相同 -> 写同一 `<device>.json` -> 冲突。缓解: 用 `MCM_DEVICE` 或 `mcmRemote device set <name>` 设唯一名。孤立条目(设备已废弃)手动编辑 JSON 清理(无法自动探测设备存活,不提供 prune)。

## 4. 新增命令

### 4.1 `mcmRemote` - remote 与 device 管理

```
mcmRemote init [--remote <url>] [--device <name>]
mcmRemote add <name> <url>
mcmRemote list
mcmRemote remove <name>
mcmRemote device [show | set <name>]
```

- `init`: 在已存在的 `$MEMORY_BASE` 里 `git init`(若已有 `.git` 则跳过,幂等);写入 §3 的 `.gitignore` + `.gitattributes`;若 `.device` 不存在则盖戳(`--device` 或 `hostname`);`git add -A` + 初始 commit `mcm: init remote store`;可选 `git remote add origin <url>` + 首次 push。**迁移老用户的主入口**。
- `add/list/remove`: 透传 `git remote add/list/remove`,统一中文输出。
- `device show`: 打印 `current_device_id()` 解析结果(来源:env / .device / hostname)。
- `device set <name>`: 写 `$MEMORY_BASE/.device` 为 `<name>`(覆盖)。用于修 hostname 冲突或重命名。
- 全程 `acquire_lock`;`emit_event` 写 `remote.init`/`remote.add`/`remote.device`。

### 4.2 `mcmPush` - 推送

```
mcmPush [--remote <name>] [--all] [--message <msg>]
```

1. `acquire_lock`。
2. `git add -A`(尊重 .gitignore,只 stage 真记忆变更)。
3. 若无 staged 变更:输出"无变更,跳过",exit 0。
4. 生成 commit message:默认从 `git diff --cached --name-only` 提取变更的记忆名(按目录路径归约,如 `projects/tools/foo/chunks/x.md` -> `tools/foo`),格式 `mcm: sync <name1>, <name2>`;`--message` 覆盖。
5. `git commit`;`log_memory_op push`;`emit_event push`。
6. push: 默认 `git push origin main`;`--remote <name>` 指定;`--all` 遍历所有 remote 逐一 push。
7. 单个 remote push 失败(网络/auth)不阻断其他 remote;汇总失败列表,exit code 反映。

### 4.3 `mcmPull` - 拉取

```
mcmPull [--remote <name>] [--abort | --ours | --theirs | --continue]
```

1. `acquire_lock`。
2. 工作区有未提交变更时:警告并要求先 commit/stash(避免 merge 污染),除非 `--continue`。
3. `git fetch <remote>` + `git merge --no-edit <remote>/main`(默认 `origin`)。
4. **成功**: 走 §5 重建派生文件;`log_memory_op pull`;`emit_event pull`;exit 0。
5. **冲突**: 不自动解决,见 §6。

## 5. 派生文件重建

### 5.1 问题

`.gitignore` 排除了 `index.md`(各层)、`.search_index`、`hash.json`。clone/pull 后这些文件缺失,直到重建。依赖它们的功能:
- `mcmSearch` 依赖 `.search_index`(v2.2 快速路径)
- `mcmLoad --layer L2` 依赖每记忆 `index.md`
- `mcmSync` 依赖 `hash.json` 做 hash-driven 增量

> L4(`.claude/l4/*.json`)是真同步数据,不在重建之列(见 §3.1)。

### 5.2 重建机制

新增 `rebuild_derived()` 函数(lib/core.sh 或 lib/remote.sh):
- 遍历所有记忆目录,从 `chunks/*.md` 重生成每记忆 `index.md`(复用 `init.sh` 的 L2 生成逻辑,抽成可复用函数 `generate_l2_index <memory_path>`)。
- `rebuild_search_index()`(已存在,core.sh:1079)重建 `.search_index`。
- 各记忆 `hash.json` 由下次 `mcmSync` 自然重算(无需主动重建;首次 sync 会补)。

### 5.3 触发时机

- `mcmPull` 成功合并后(步骤 4)。
- 新机 clone 后的首次 `mcmDoctor` / `mcmLoad`(doctor 已有 canary 验证管线,顺手触发重建)。
- `mcmRemote init` 不触发(本地已有,gitignore 仅影响未来 add)。

## 6. 冲突处理策略

### 6.1 冲突面

| 文件 | 冲突风险 | 处理 |
|------|----------|------|
| `log.md` / `ledger.md` | 无(union) | 自动合并 |
| `.claude/l4/<device>.json` | 无(每设备独立文件) | 不同设备不撞;同设备并发罕见 |
| `summary.md` | 中(并发 `mcmUpdate`) | 人工 |
| `chunks/*.md` | 低(偶尔 AI 并发编辑同 chunk) | 人工 |

### 6.2 UX

`mcmPull` 检测到 merge 冲突(git 非 0 退出):
1. **不自动 abort**,保留 merge-in-progress 状态,让用户看到冲突标记。
2. 打印冲突文件清单 + 引导:
   ```
   检测到冲突,需手动解决:
     projects/foo/summary.md
   解决后: mcmPull --continue   (提交合并)
   放弃:   mcmPull --abort       (回到合并前)
   单方:   mcmPull --ours|--theirs <file>
   ```
3. `--continue` = `git commit`(完成合并)+ §5.3 重建。
4. `--abort` = `git merge --abort`。
5. `--ours`/`--theirs <file>` = `git checkout --ours/--theirs <file>` + `git add`。

**原则**: 永不静默自动解决改写式文件;冲突必须人工裁定。append-only 由 union 兜底,L4 由 per-device 文件隔离兜底。

## 7. SessionStart 自动 pull(opt-in)

### 7.1 配置

- `MCM_AUTOPULL=1`(默认 off)开启 SessionStart 自动 pull。
- 尊重现有 kill-switch: `.stop`(v3.2 STOP)或 `.paused`(v2.4 pause)存在时跳过,与 v3.6 ledger 注入一致(不走 BM25/cooldown,但尊重 STOP/pause)。

### 7.2 行为

SessionStart hook(`session_start_inject` 加载 L1+L3 之后)追加:

```bash
if [[ "${MCM_AUTOPULL:-0}" == "1" ]] && ! is_stopped && ! is_inject_paused; then
    git -C "$MEMORY_BASE" pull --ff-only origin main 2>/dev/null \
        && log "auto-pull: fast-forwarded" \
        || log "auto-pull: 非快进或失败,请手动 mcmPull"
fi
```

**关键: `--ff-only`**。fast-forward 时不产生 merge commit、不可能冲突;落后且无法快进时静默跳过并提示,绝不阻塞会话。需要真正 merge 的情形交给手动 `mcmPull`。

### 7.3 事件

`emit_event` 写 `autoppull.ok` / `autoppull.skip`。

## 8. 跨平台

- **L4**: device-keyed JSON registry(§3.1),彻底弃用软链 -> Windows 无软链问题。每设备独立文件,git 合并零冲突。
- **`.workspace`**: gitignore;新机各项目用 `mcmInit --name <existing>` 重新绑定本机路径(B2 修复支持显式 name 直查)。
- **行尾**: `.gitattributes` 显式 `* text=auto eol=lf`,避免 CRLF 污染 frontmatter 解析。
- **身份**: 不强制设置;复用全局 git identity。若缺失,`mcmRemote init` 警告(不阻断)。

## 9. 引导与迁移

### 9.1 老用户(已有记忆,无 git)

```
mcmRemote init --remote git@github.com:me/my-memories.git
# -> git init + .gitignore/.gitattributes + .device 盖戳 + 首次 commit + remote add + push
```

### 9.2 新机器

```
git clone git@github.com:me/my-memories.git ~/.claude/mcMemories
mcmRemote device          # 确认本机 device id(首次自动用 hostname 盖戳到 .device)
mcmDoctor                 # 重建 .search_index + index.md + canary 自检
# 对每个本地项目:
cd ~/project/foo && mcmInit --name foo   # 绑定 .workspace + 记录本机 L4(写 .claude/l4/<device>.json)
mcmPull                   # 拉取最新(L4 是同步数据,无需重建)
```

## 10. 错误处理

| 情况 | 处理 |
|------|------|
| `mcmPush` 时无 remote 配置 | 报错"未配置 remote,先 mcmRemote add" |
| push 网络失败 | 不阻断其他 remote;汇总失败;非 0 退出 |
| `mcmPull` 工作区脏 | 拒绝并提示 commit/stash,除非 `--continue` |
| pull 冲突 | §6,不自动解决 |
| `mcmRemote init` 已有 .git | 跳过 init,仅补 .gitignore/.gitattributes(幂等) |
| `current_device_id` 两机 hostname 撞 | `mcmRemote device set` 改唯一名 |
| git 未安装 | `mcmRemote init` 前置检查,报错 |

## 11. 测试计划(供 writing-plans 参考)

- 单元: `.gitignore`/`.gitattributes` 正确分类;`rebuild_derived` 重建 index.md/search_index;commit message 生成;`current_device_id` 三级解析;`record_l4_source`/`resolve_l4_source` 读写 device JSON。
- 集成: init->push->clone->pull 全链路;append-only 文件 union 合并(两机并发追加 log.md 无冲突);L4 per-device 文件两设备并发写不撞;summary.md 冲突走 §6 不静默丢失;`--ff-only` auto-pull 落后时跳过不阻塞;STOP/pause 时 auto-pull 跳过;`mcmRemote init` 幂等;新机 clone 后 `mcmInit --name` 写入本机 L4。
- 回归: 现有 209 断言不回归(remote 功能独立;L4 API 重构需保证 init/sync/load 调用点行为不变)。

## 12. 开放问题 / 实现注意

1. **`generate_l2_index` 抽取**: `init.sh:100-129` 的 L2 生成逻辑需抽成 `lib/core.sh` 可复用函数,供 `rebuild_derived` 与 init 共用。注意 tags 当前硬编码 `[general]`(已知限制,不在本期修)。
2. **L4 API 重构兼容**: `create_l4_link` 改为 `record_l4_source` 后,所有调用点(init/sync)及读 L4 的路径(`core.sh:487` 一带)须同步改读 device JSON。需确认无其他隐藏的 L4 读路径。
3. **锁与 git**: `mcmPush`/`mcmPull` 复用 `acquire_lock`;但 git 操作本身不改记忆内容(改的是 .git),故与记忆写锁同一把锁即可,不引入新锁。
4. **大仓库性能**: 单 repo 全量历史可能增长;`log.md`/`ledger.md` append-only 会无限增长。未来可加 `mcmGc`(压缩历史),不在本期。
5. **device id 稳定性**: `.device` 一旦盖戳即持久;改 hostname 不会自动改 `.device`(设计如此,避免 L4 条目失联)。改名走 `mcmRemote device set`。

## 13. 命令速查

| 命令 | 用途 |
|------|------|
| `mcmRemote init [--remote <url>] [--device <name>]` | git init + 配置文件 + .device 盖戳 + 首次提交/推送 |
| `mcmRemote add/list/remove` | remote 管理 |
| `mcmRemote device [show\|set <name>]` | 查看/设置本机 device id |
| `mcmPush [--remote <name>] [--all]` | 提交并推送变更 |
| `mcmPull [--remote <name>] [--abort\|--ours\|--theirs\|--continue]` | 拉取并合并,冲突不静默 |

环境变量: `MCM_AUTOPULL`(SessionStart 自动 ff-only pull,默认 off)、`MCM_DEVICE`(覆盖 device id)。
