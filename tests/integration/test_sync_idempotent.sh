#!/bin/bash
# ============================================================================
# 集成测试 2: sync 幂等性（v3.0 / Phase 0 A5-first）
# ============================================================================
# 验证:
#   - init → sync 不变更（hash.json 一致，搜索索引行数稳定）
#   - 修改一个源文件 → sync 仅那个 chunk 更新（hash.json 该 key 变更）
#   - 事件流见证 cmd.start/cmd.end 配对，sync 退出码正确
# ============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
source "$PROJECT_DIR/lib/core.sh"

# 准备一个最小的 workspace（CLAUDE.md + package.json）然后 init
# B2 已修复 (v3.1): find_project_memory_dir 现在按 .workspace 标记 + basename
# 回退查找，不再强制要求"目录名 = --name"。此处仍用 int-fixture 仅为历史惯例；
# 自定义命名场景由 it_sync_finds_custom_named_project 单独覆盖。
_seed_workspace_and_init() {
    local ws="$INT_FIXTURE_DIR/int-fixture"
    mkdir -p "$ws"
    ( cd "$ws" && git init -q && git config user.email t@x && git config user.name t )
    cat > "$ws/CLAUDE.md" <<'EOF'
# Test Project

## Architecture
Pure bash CLI for memory management.

## Commands
- foo: do foo
- bar: do bar
EOF
    cat > "$ws/package.json" <<'EOF'
{"name": "int-test-fixture", "version": "1.0.0"}
EOF
    # init 项目记忆（非交互，给完整参数）
    bash "$PROJECT_DIR/commands/init.sh" \
        --name "int-fixture" \
        --tags "tools" \
        --description "integration test fixture" \
        --workspace "$ws" > /tmp/init.out 2>&1
    echo "$ws"
}

# ----------------------------------------------------------------------------
it_init_then_sync_no_changes() {
    local ws
    ws=$(_seed_workspace_and_init)

    local mem_dir="$PROJECTS_DIR/tools/int-fixture"
    assert_file_exists "$mem_dir/hash.json" "init 创建 hash.json"
    assert_file_exists "$mem_dir/summary.md" "init 创建 summary.md"

    # 记录 init 后状态快照
    local index_lines_before hash_before
    index_lines_before=$(wc -l < "$SEARCH_INDEX" 2>/dev/null || echo 0)
    hash_before=$(sha256sum "$mem_dir/hash.json" | awk '{print $1}')

    # 立即 sync，应无变化
    bash "$PROJECT_DIR/commands/sync.sh" --workspace "$ws" > /tmp/sync1.out 2>&1
    local sync_exit=$?
    assert_equal "0" "$sync_exit" "sync 退出码 0"
    assert_contains "无变化" "$(cat /tmp/sync1.out)" "sync 输出'无变化'"

    local index_lines_after hash_after
    index_lines_after=$(wc -l < "$SEARCH_INDEX" 2>/dev/null || echo 0)
    hash_after=$(sha256sum "$mem_dir/hash.json" | awk '{print $1}')
    assert_equal "$index_lines_before" "$index_lines_after" "搜索索引行数不变"
    assert_equal "$hash_before" "$hash_after" "hash.json 哈希不变（幂等）"
}

# ----------------------------------------------------------------------------
it_sync_detects_source_change() {
    local ws
    ws=$(_seed_workspace_and_init)
    local mem_dir="$PROJECTS_DIR/tools/int-fixture"

    # 修改 CLAUDE.md
    echo "" >> "$ws/CLAUDE.md"
    echo "## New section added later" >> "$ws/CLAUDE.md"
    echo "Some new content to trigger sync detection." >> "$ws/CLAUDE.md"

    local hash_before
    hash_before=$(sha256sum "$mem_dir/hash.json" | awk '{print $1}')

    bash "$PROJECT_DIR/commands/sync.sh" --workspace "$ws" > /tmp/sync2.out 2>&1
    local sync_exit=$?
    assert_equal "0" "$sync_exit" "sync 退出码 0"

    # 输出应表明检测到变化（而非"无变化"）
    assert_not_contains "无变化" "$(cat /tmp/sync2.out)" "sync 检测到变化"

    local hash_after
    hash_after=$(sha256sum "$mem_dir/hash.json" | awk '{print $1}')
    if [ "$hash_before" = "$hash_after" ]; then
        echo -e "  ${RED}FAIL${NC} hash.json 在源文件变化后应更新"
        FAILED=$((FAILED + 1))
    else
        echo -e "  ${GREEN}PASS${NC} hash.json 在源文件变化后更新"
        PASSED=$((PASSED + 1))
    fi
}

# ----------------------------------------------------------------------------
it_sync_emits_cmd_events() {
    local ws
    ws=$(_seed_workspace_and_init)

    # 清空事件，单独跑 sync 看新增的事件
    : > "$MCM_EVENTS_FILE"
    bash "$PROJECT_DIR/commands/sync.sh" --workspace "$ws" > /tmp/sync3.out 2>&1

    local n_start n_end
    n_start=$(count_events 'cmd\.start')
    n_end=$(count_events 'cmd\.end')
    assert_equal "1" "$n_start" "cmd.start 恰一次"
    assert_equal "1" "$n_end" "cmd.end 恰一次"

    # cmd.end 的 exit 字段
    local exits
    exits=$(events_field 'cmd\.end' 'exit')
    assert_contains "0" "$exits" "cmd.end exit=0"
}

# ----------------------------------------------------------------------------
it_sync_releases_lock_on_normal_exit() {
    local ws
    ws=$(_seed_workspace_and_init)

    # 正常 sync 后 .locks 目录应无残留
    bash "$PROJECT_DIR/commands/sync.sh" --workspace "$ws" > /dev/null 2>&1

    local lock_count
    lock_count=$(ls -1 "$MEMORY_BASE/.locks/" 2>/dev/null | wc -l | tr -d ' ')
    assert_equal "0" "$lock_count" "sync 后无锁残留"
}

# ----------------------------------------------------------------------------
it_sync_finds_custom_named_project() {
    # B2 回归：workspace 目录名 ≠ --name 时，sync 仍能凭 .workspace 标记找到记忆
    local ws="$INT_FIXTURE_DIR/custom-ws-dir"   # 目录名 ≠ --name
    mkdir -p "$ws"
    ( cd "$ws" && git init -q && git config user.email t@x && git config user.name t )
    cat > "$ws/CLAUDE.md" <<'EOF'
# Custom Named Project
## Architecture
B2 regression fixture.
EOF
    bash "$PROJECT_DIR/commands/init.sh" \
        --name "my-custom-name" \
        --tags "tools" \
        --description "B2 regression fixture" \
        --workspace "$ws" > /tmp/init_b2.out 2>&1

    # 记忆应建在 my-custom-name 下（而非目录名 custom-ws-dir）
    local mem_dir="$PROJECTS_DIR/tools/my-custom-name"
    assert_file_exists "$mem_dir/hash.json" "init 用 --name 建目录（非目录名）"
    assert_file_exists "$mem_dir/.workspace" "init 写 .workspace 标记"
    assert_contains "custom-ws-dir" "$(cat "$mem_dir/.workspace" 2>/dev/null)" \
        ".workspace 标记指向正确 workspace"

    # sync 不带 --name，应通过 .workspace 标记找到记忆（而非 basename 启发式）
    bash "$PROJECT_DIR/commands/sync.sh" --workspace "$ws" > /tmp/sync_b2.out 2>&1
    local sync_exit=$?
    assert_equal "0" "$sync_exit" "B2: 自定义名项目 sync 退出码 0"
    assert_not_contains "未找到项目记忆" "$(cat /tmp/sync_b2.out)" "B2: sync 找到自定义名项目"
    assert_contains "无变化" "$(cat /tmp/sync_b2.out)" "B2: sync 幂等"
}

# ----------------------------------------------------------------------------
IT_LIST=(
    "init then immediate sync is idempotent"  it_init_then_sync_no_changes
    "sync detects source change"              it_sync_detects_source_change
    "sync emits paired cmd.start/cmd.end"     it_sync_emits_cmd_events
    "sync releases lock on normal exit"       it_sync_releases_lock_on_normal_exit
    "B2: sync finds custom-named project"     it_sync_finds_custom_named_project
)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_its "sync 幂等性" "${IT_LIST[@]}"
fi
