#!/bin/bash
# ============================================================================
# 集成测试 5: Phase 2 可观测性（op-log / STOP / drift / canary）(v3.2)
# ============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
source "$PROJECT_DIR/lib/core.sh"
source "$PROJECT_DIR/lib/inject.sh"

_seed_workspace() {
    local ws="$INT_FIXTURE_DIR/phase2-ws"
    mkdir -p "$ws"
    ( cd "$ws" && git init -q && git config user.email t@x && git config user.name t )
    cat > "$ws/CLAUDE.md" <<'EOF'
# Phase2 Test Project
## Architecture
observability features.
EOF
    echo "$ws"
}

# ----------------------------------------------------------------------------
it_op_log_records_init_and_sync() {
    local ws
    ws=$(_seed_workspace)
    bash "$PROJECT_DIR/commands/init.sh" \
        --name "oplog-proj" --tags "tools" \
        --description "oplog test" --workspace "$ws" > /dev/null 2>&1

    local mem_dir="$PROJECTS_DIR/tools/oplog-proj"
    assert_file_exists "$mem_dir/log.md" "init 写 op-log"
    assert_contains "init" "$(cat "$mem_dir/log.md")" "op-log 含 init 记录"

    # sync 应追加 sync 记录
    bash "$PROJECT_DIR/commands/sync.sh" --workspace "$ws" > /dev/null 2>&1
    assert_contains "sync" "$(cat "$mem_dir/log.md")" "op-log 含 sync 记录"

    # grep '^## \[' 应返回时间线（init + sync ≥ 2）
    local n
    n=$(grep -c '^## \[' "$mem_dir/log.md" 2>/dev/null || echo 0)
    assert_ge "$n" "2" "op-log 时间线 ≥ 2 条"
}

# ----------------------------------------------------------------------------
it_stop_suppresses_injection() {
    # v3.5: inject.sh 已惰性求值，不再在 source 时冻结 INJECT_STOP_FILE，
    # 故无需重 source —— is_inject_stopped 在调用时读现行 $MEMORY_BASE。
    local ws
    ws=$(_seed_workspace)
    bash "$PROJECT_DIR/commands/init.sh" \
        --name "stop-proj" --tags "tools" \
        --description "stop test" --workspace "$ws" > /dev/null 2>&1

    # 全局停止
    bash "$PROJECT_DIR/commands/auto-inject.sh" stop > /dev/null 2>&1
    assert_file_exists "$MEMORY_BASE/.stop" "stop 创建 .stop 文件"

    # 跑 prompt_submit（含匹配关键词），应被 STOP 短路
    : > "$MCM_EVENTS_FILE"
    prompt_submit_inject "observability architecture features" > /dev/null 2>&1

    local n_stopped n_normal
    n_stopped=$(count_events 'inject\.stopped')
    n_normal=$(count_events 'inject\.prompt_submit')
    assert_ge "$n_stopped" "1" "STOP 期发 inject.stopped 事件"
    assert_equal "0" "$n_normal" "STOP 期绝无 inject.prompt_submit"

    # unstop 后恢复
    bash "$PROJECT_DIR/commands/auto-inject.sh" unstop > /dev/null 2>&1
    if [ ! -f "$MEMORY_BASE/.stop" ]; then
        echo -e "  ${GREEN}PASS${NC} unstop 移除 .stop"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC} unstop 未移除 .stop"
        FAILED=$((FAILED + 1))
    fi
}

# ----------------------------------------------------------------------------
it_drift_reports_orphan_and_broken_l4() {
    local ws
    ws=$(_seed_workspace)
    bash "$PROJECT_DIR/commands/init.sh" \
        --name "drift-proj" --tags "tools" \
        --description "drift test" --workspace "$ws" > /dev/null 2>&1

    # 删除源文件 → chunk 变 orphan + L4 链接变 broken
    rm -f "$ws/CLAUDE.md"
    # 让 chunk 显得陈旧
    local mem_dir="$PROJECTS_DIR/tools/drift-proj"
    touch -d "2020-01-01" "$mem_dir/chunks/1_CLAUDE.md" 2>/dev/null

    MCM_DRIFT_STALE_DAYS=30 bash "$PROJECT_DIR/commands/status.sh" --drift > /tmp/drift.out 2>&1
    local out
    out=$(cat /tmp/drift.out)
    # v3.3: 评分制报告（100 点 + 等级 + 详情列表）
    assert_not_contains "无 drift 信号" "$out" "drift 报告检测到问题"
    assert_contains "broken-l4:" "$out" "drift 详情含 broken-l4"
    assert_contains "orphan:" "$out" "drift 详情列 orphan"
    assert_contains "stale:" "$out" "drift 详情列 stale"
    assert_contains "评分制" "$out" "drift 报告为 v3.3 评分制"
    # 分数应低于 100（broken+orphan+stale+placeholder 扣分）
    local score
    score=$(printf '%s' "$out" | grep -oE '\| [0-9]+ \|' | head -1 | grep -oE '[0-9]+')
    [ -n "$score" ] && assert_ge 99 "$score" "drift 分数 < 100 (实得 $score)"
}

# ----------------------------------------------------------------------------
it_doctor_canary_passes() {
    bash "$PROJECT_DIR/commands/doctor.sh" > /tmp/doctor.out 2>&1
    local out
    out=$(cat /tmp/doctor.out)

    assert_contains "canary 命中" "$out" "doctor canary 端到端通过"
    assert_file_exists "$GLOBAL_DIR/.canary/_mcm_canary/chunks/1_canary.md" "canary 探针 chunk 存在"

    # canary 不污染 mcmList
    local listing
    listing=$(bash "$PROJECT_DIR/commands/list.sh" 2>/dev/null)
    assert_not_contains "_mcm_canary" "$listing" "canary 不出现在 mcmList"
}

# ----------------------------------------------------------------------------
IT_LIST=(
    "op-log records init + sync timeline"   it_op_log_records_init_and_sync
    "global STOP suppresses injection"       it_stop_suppresses_injection
    "drift reports orphan + broken L4"       it_drift_reports_orphan_and_broken_l4
    "doctor canary end-to-end passes"       it_doctor_canary_passes
)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_its "Phase 2 可观测性" "${IT_LIST[@]}"
fi
