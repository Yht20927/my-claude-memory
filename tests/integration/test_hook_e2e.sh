#!/bin/bash
# ============================================================================
# 集成测试 1: hook 端到端（v3.0 / Phase 0 A5-first）
# ============================================================================
# 拦本轮 P0 真因链中的：
#   - inject 路径完整性（keyword→find→score→inject）
#   - hook 短路 / pause / 注入命中 三类路径在事件流中都有可追溯痕迹
#   - 即使 inject 失败也不影响 hook 总输出（USER_PROMPT 必出现在 stdout）
# ============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
source "$PROJECT_DIR/lib/core.sh"   # 拿到 $PYTHON
source "$PROJECT_DIR/lib/inject.sh" # 拿到 INJECT_PAUSE_FILE 等常量

# 准备一个最小项目记忆（chunk 含中文内容，触发 prompt 注入用）
_seed_project_memory() {
    local mem_dir="$MEMORY_BASE/global/auto/mcm-int-fixture"
    mkdir -p "$mem_dir/chunks"
    cat > "$mem_dir/summary.md" <<EOF
# mcm-int-fixture
Fixture 全局记忆，用于集成测试触发注入。
EOF
    cat > "$mem_dir/index.md" <<EOF
# 索引
- chunks/about_bm25.md - BM25 评分算法说明
EOF
    cat > "$mem_dir/chunks/about_bm25.md" <<EOF
---
title: BM25 评分算法说明
tags: [auto, search, bm25]
---
# BM25 评分

BM25 是 mcMemory v2.4 使用的相关性评分算法。
它替代了原来的 sqrt(n) 归一化方案，能更好处理高频低 IDF 词的污染。
关键参数：k1=1.2、b=0.75。
EOF

    # 重建索引（hook 内部也会做，但显式做避免首次走慢路径）
    rebuild_search_index 2>/dev/null || true
}

# ----------------------------------------------------------------------------
it_session_start_emits_paired_events() {
    _seed_project_memory
    bash "$PROJECT_DIR/hooks/session-start.sh" "$INT_FIXTURE_DIR" > /tmp/ss.out 2>&1

    local invokes completes
    invokes=$(count_events 'hook\.invoke')
    completes=$(count_events 'hook\.complete')
    assert_equal "1" "$invokes" "hook.invoke 恰一次"
    assert_equal "1" "$completes" "hook.complete 恰一次"

    # invoke / complete 都应带 kind=session_start
    local kinds
    kinds=$(events_field 'hook\..*' 'kind')
    assert_contains "session_start" "$kinds" "事件 kind=session_start"
}

# ----------------------------------------------------------------------------
it_prompt_submit_short_circuits() {
    # 短 prompt (< 10 字符) 必须短路：emit hook.invoke + hook.complete short_circuit=1
    echo "ok" | bash "$PROJECT_DIR/hooks/prompt-submit.sh" > /tmp/ps.out 2>&1

    # USER_PROMPT 必须原样出现在 stdout
    assert_equal "ok" "$(cat /tmp/ps.out)" "短 prompt 原样输出"

    # 没有任何 inject.* 事件（被短路掉了）
    local n_inject
    n_inject=$(count_events 'inject\.')
    assert_equal "0" "$n_inject" "短 prompt 不触发 inject"

    # hook.complete 应带 short_circuit=1
    local sc
    sc=$(events_field 'hook\.complete' 'short_circuit')
    assert_contains "1" "$sc" "hook.complete 标 short_circuit=1"
}

# ----------------------------------------------------------------------------
it_prompt_submit_hits_relevant_chunk() {
    _seed_project_memory
    # 中文 prompt 命中 BM25 chunk（验证 P0 的中文 token 修复仍生效）
    local out
    out=$(echo "BM25 评分算法是怎么实现的？" | bash "$PROJECT_DIR/hooks/prompt-submit.sh" 2>&1)

    # USER_PROMPT 一定在尾部（hook 设计）
    assert_contains "BM25 评分算法是怎么实现的？" "$out" "USER_PROMPT 原样附带"

    # inject.prompt_submit 必然发出
    local n_inject
    n_inject=$(count_events 'inject\.prompt_submit')
    assert_ge "$n_inject" "1" "至少发 1 条 inject.prompt_submit"

    # 注入内容应出现在 stdout（包装在 mcMemory 注释里）
    assert_contains "mcMemory auto-inject" "$out" "stdout 含注入标记"
}

# ----------------------------------------------------------------------------
it_paused_inject_logs_paused_event() {
    _seed_project_memory
    # 设置 pause 标记到 1 小时后
    local pause_until=$(( $(date +%s) + 3600 ))
    echo "$pause_until" > "$MEMORY_BASE/.paused_until"

    local out
    out=$(echo "BM25 是怎么实现的？" | bash "$PROJECT_DIR/hooks/prompt-submit.sh" 2>&1)

    # 应有 inject.paused，绝对不能有 inject.prompt_submit
    local n_paused n_normal
    n_paused=$(count_events 'inject\.paused')
    n_normal=$(count_events 'inject\.prompt_submit')
    assert_ge "$n_paused" "1" "暂停期内至少 1 条 inject.paused"
    assert_equal "0" "$n_normal" "暂停期内绝无 inject.prompt_submit"

    # 注入标记不应进入 stdout
    assert_not_contains "mcMemory auto-inject" "$out" "暂停后 stdout 无注入标记"
}

# ----------------------------------------------------------------------------
it_placeholder_chunk_excluded_from_inject() {
    # P0 真因链之一：占位 chunk 内容是 [待AI补充] 不能被注入
    local mem_dir="$MEMORY_BASE/global/auto/placeholder-fixture"
    mkdir -p "$mem_dir/chunks"
    cat > "$mem_dir/summary.md" <<EOF
# placeholder-fixture
含占位 chunk 的记忆。
EOF
    cat > "$mem_dir/chunks/empty.md" <<EOF
---
title: 占位 chunk
tags: [auto]
---
# 占位 chunk
[待AI补充：浓缩内容]
EOF
    rebuild_search_index 2>/dev/null || true

    local out
    out=$(echo "占位 chunk 浓缩内容相关问题？" | bash "$PROJECT_DIR/hooks/prompt-submit.sh" 2>&1)

    # 占位标记绝不能出现在 stdout 注入区
    assert_not_contains "[待AI补充" "$out" "占位 chunk 不进入注入"
}

# ----------------------------------------------------------------------------
IT_LIST=(
    "session_start emits paired hook.invoke + hook.complete" it_session_start_emits_paired_events
    "prompt_submit short-circuits on tiny input"               it_prompt_submit_short_circuits
    "prompt_submit hits relevant chunk (中文 token 修复)"        it_prompt_submit_hits_relevant_chunk
    "paused inject emits inject.paused, suppresses normal"     it_paused_inject_logs_paused_event
    "placeholder chunk excluded from injection"                 it_placeholder_chunk_excluded_from_inject
)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_its "hook 端到端" "${IT_LIST[@]}"
fi
