#!/bin/bash
# ============================================================================
# 集成测试 3: 并发安全（v3.0 / Phase 0 A5-first）
# ============================================================================
# 验证:
#   - 10 个 sync 并发同一记忆 → flock 串行化，无 hash.json 损坏，无锁残留
#   - sync 进行时 inject 不撕裂（不会读到半写状态的索引）
#   - 事件流见证 10 个 cmd.start + 10 个 cmd.end 配对完整
# ============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
source "$PROJECT_DIR/lib/core.sh"

# 与 sync_idempotent 共用 fixture 构造（git repo + --name 同名目录）
_seed_workspace_and_init() {
    local ws="$INT_FIXTURE_DIR/int-fixture"
    mkdir -p "$ws"
    ( cd "$ws" && git init -q && git config user.email t@x && git config user.name t )
    cat > "$ws/CLAUDE.md" <<'EOF'
# Concurrent Test
## Architecture
Bash CLI concurrent safety test.
## Commands
- one: first cmd
- two: second cmd
EOF
    bash "$PROJECT_DIR/commands/init.sh" \
        --name "int-fixture" \
        --tags "tools" \
        --description "concurrent test fixture" \
        --workspace "$ws" > /dev/null 2>&1
    echo "$ws"
}

# ----------------------------------------------------------------------------
# 10 并发 sync 同一记忆，验证无损坏 + 锁释放干净
it_10_concurrent_syncs_no_corruption() {
    local ws
    ws=$(_seed_workspace_and_init)
    local mem_dir="$PROJECTS_DIR/tools/int-fixture"

    # 修改源文件，让每次 sync 都有真活儿干（避免"无变化"快路径）
    echo "## extra $(date +%s%N)" >> "$ws/CLAUDE.md"

    : > "$MCM_EVENTS_FILE"
    local pids=()
    local i
    for i in $(seq 1 10); do
        bash "$PROJECT_DIR/commands/sync.sh" --workspace "$ws" > "/tmp/csync_$i.out" 2>&1 &
        pids+=($!)
    done

    # 等所有 sync 完成
    local all_ok=true
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            all_ok=false
        fi
    done

    if [ "$all_ok" = true ]; then
        echo -e "  ${GREEN}PASS${NC} 10 个并发 sync 都返回 0"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC} 至少一个并发 sync 失败"
        FAILED=$((FAILED + 1))
    fi

    # hash.json 必须仍是合法 JSON
    if $PYTHON -c "import json; json.load(open('$mem_dir/hash.json'))" 2>/dev/null; then
        echo -e "  ${GREEN}PASS${NC} hash.json 仍是合法 JSON（未被撕裂）"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC} hash.json 损坏"
        FAILED=$((FAILED + 1))
    fi

    # 搜索索引必须存在且非空
    assert_file_exists "$SEARCH_INDEX" "搜索索引仍存在"
    local idx_lines
    idx_lines=$(wc -l < "$SEARCH_INDEX" 2>/dev/null || echo 0)
    assert_ge "$idx_lines" "1" "搜索索引非空（行数 $idx_lines）"

    # 所有锁必须已释放（核心断言：flock 串行化后无残留）
    local lock_count
    lock_count=$(ls -1 "$MEMORY_BASE/.locks/" 2>/dev/null | wc -l | tr -d ' ')
    assert_equal "0" "$lock_count" "10 并发后锁目录无残留"

    # 事件流：10 cmd.start + 10 cmd.end
    local n_start n_end
    n_start=$(count_events 'cmd\.start')
    n_end=$(count_events 'cmd\.end')
    assert_equal "10" "$n_start" "事件流见证 10 个 cmd.start"
    assert_equal "10" "$n_end" "事件流见证 10 个 cmd.end"

    # 所有 cmd.end 的 exit 字段必须都是 0
    local non_zero_exits
    non_zero_exits=$($PYTHON -c "
import json
n = 0
with open('$MCM_EVENTS_FILE') as f:
    for line in f:
        try: o = json.loads(line)
        except: continue
        if o.get('type') == 'cmd.end' and o.get('exit') != '0':
            n += 1
print(n)
")
    assert_equal "0" "$non_zero_exits" "所有 cmd.end exit=0（无并发触发的失败）"
}

# ----------------------------------------------------------------------------
# sync 进行时 inject 应读到一致的索引（旧版或新版，不撕裂）
# 用 background sync + 同时多次 prompt_submit 触发 inject
it_inject_during_sync_no_torn_read() {
    local ws
    ws=$(_seed_workspace_and_init)

    # 后台开一个长 sync（用 strace-like 拖慢路径不现实，靠重复修改文件触发完整流）
    echo "## extra section $(date +%s%N)" >> "$ws/CLAUDE.md"
    bash "$PROJECT_DIR/commands/sync.sh" --workspace "$ws" > /dev/null 2>&1 &
    local sync_pid=$!

    # 同时跑 5 次 prompt_submit
    local i fail=0
    for i in $(seq 1 5); do
        # inject 失败（exit ≠ 0）即算撕裂候选
        if ! echo "bash CLI concurrent test ${i}" | \
             bash "$PROJECT_DIR/hooks/prompt-submit.sh" > "/tmp/cinj_$i.out" 2>&1; then
            fail=$((fail + 1))
        fi
    done

    wait "$sync_pid"
    local sync_exit=$?
    assert_equal "0" "$sync_exit" "并发期间 sync 仍成功"
    assert_equal "0" "$fail" "并发期间 5 次 inject 都不报错"

    # 每次 inject 都应有 USER_PROMPT 原样输出（hook 设计）
    local all_have_prompt=true
    for i in $(seq 1 5); do
        if ! grep -q "bash CLI concurrent test" "/tmp/cinj_$i.out"; then
            all_have_prompt=false
            break
        fi
    done
    if $all_have_prompt; then
        echo -e "  ${GREEN}PASS${NC} 每次 inject 都原样附带 USER_PROMPT"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC} 某次 inject 丢失 USER_PROMPT"
        FAILED=$((FAILED + 1))
    fi
}

# ----------------------------------------------------------------------------
IT_LIST=(
    "10 concurrent syncs: no corruption, no lock leak"  it_10_concurrent_syncs_no_corruption
    "inject during sync: no torn read"                   it_inject_during_sync_no_torn_read
)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_its "并发安全" "${IT_LIST[@]}"
fi
