# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

mcMemory (mcm) is a Claude Code skill that implements a hierarchical memory management system in pure Bash (v2.3). It persists project and personal knowledge to `~/.claude/mcMemories/` so AI context survives across sessions.

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
| L4 | References to original source files (project only) | `.claude/` (symlinks or `.source` files) |

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

### L4 links use relative paths

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
| `mcmStatus` | Health overview, freshness, trash status |
| `mcmUpdate` | Update name/description/tags (tags now work) |
| `mcmDelete` | Move to trash |
| `mcmExport` | Export memory as tar.gz |
| `mcmImport` | Import from tar.gz archive |
| `mcmRestore` | Restore from trash |
| `mcmEmptyTrash` | Permanently empty trash |

Common flags: `--global`, `--json` (list/search/status), `--expand` (search), `--force` (delete/empty-trash).

## AI condensation flow (important)

After `mcmInit` or `mcmSync`, chunk files may contain `[待AI补充：浓缩内容]`. Claude should:
1. Read each chunk's `source_file` from its YAML frontmatter
2. Read the source file with the `Read` tool
3. Generate structured condensed content (10-30% of original, keeping key decisions/APIs/patterns)
4. Use `Edit` to replace the placeholder with actual content

Global memories with `auto` tag should be auto-loaded at session start via `mcmLoad --layer L3`.
