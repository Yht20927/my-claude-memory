#!/bin/bash
# ============================================================================
# 集成测试 6: Phase 3 评分制 + 证据分层 (v3.3)
# ----------------------------------------------------------------------------
# 3a: drift 评分制 —— 干净记忆 100/A；问题记忆扣分 + 等级
# 3b: 证据/来源分层 —— BM25 × source_w × evidence_w；mcmMark 提升 chunk 权重
# ============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
source "$PROJECT_DIR/lib/core.sh"
source "$PROJECT_DIR/lib/inject.sh"

_seed_ws() {
    local ws="$INT_FIXTURE_DIR/p3-ws"
    mkdir -p "$ws"
    ( cd "$ws" && git init -q && git config user.email t@x && git config user.name t )
    cat > "$ws/CLAUDE.md" <<'EOF'
# P3 Project
## Architecture
phase three scoring and evidence layering.
EOF
    echo "$ws"
}

# ----------------------------------------------------------------------------
# 3a: 干净记忆应得 100/A（仅 placeholder 扣分时仍 ≥98）
# ----------------------------------------------------------------------------
it_drift_clean_memory_high_score() {
    local ws
    ws=$(_seed_ws)
    bash "$PROJECT_DIR/commands/init.sh" \
        --name "clean-proj" --tags "tools" \
        --description "clean test" --workspace "$ws" > /dev/null 2>&1

    bash "$PROJECT_DIR/commands/status.sh" --drift > /tmp/p3_clean.out 2>&1
    local out
    out=$(cat /tmp/p3_clean.out)
    assert_contains "评分制" "$out" "drift v3.3 评分制"
    assert_contains "舰队均值" "$out" "drift 报告含舰队均值"
    local score
    score=$(printf '%s' "$out" | grep -oE '\| [0-9]+ \|' | head -1 | grep -oE '[0-9]+')
    [ -n "$score" ] && assert_ge "$score" "98" "干净记忆分数 ≥98 (实得 $score; 仅 placeholder -2)"
}

# ----------------------------------------------------------------------------
# 3a: 索引缺失检测 —— chunk 存在但未被索引收录
# ----------------------------------------------------------------------------
it_drift_detects_index_mismatch() {
    local ws
    ws=$(_seed_ws)
    bash "$PROJECT_DIR/commands/init.sh" \
        --name "mismatch-proj" --tags "tools" \
        --description "mismatch test" --workspace "$ws" > /dev/null 2>&1

    # init 后索引已建；手动塞一个未被索引的 chunk
    local mem_dir="$PROJECTS_DIR/tools/mismatch-proj"
    cat > "$mem_dir/chunks/2_orphan_index.md" <<'EOF'
---
source_file: ""
source: agent
evidence: observed
---
unindexed chunk content
EOF

    bash "$PROJECT_DIR/commands/status.sh" --drift > /tmp/p3_mm.out 2>&1
    local out
    out=$(cat /tmp/p3_mm.out)
    assert_contains "index-mismatch" "$out" "drift 检测到索引缺失"
    assert_contains "2_orphan_index.md" "$out" "drift 列出未索引 chunk 名"
}

# ----------------------------------------------------------------------------
# 3b: 索引元数据行 —— init 后每个 section header 后有 mcm-meta 行
# ----------------------------------------------------------------------------
it_index_emits_meta_line() {
    local ws
    ws=$(_seed_ws)
    bash "$PROJECT_DIR/commands/init.sh" \
        --name "meta-proj" --tags "tools" \
        --description "meta test" --workspace "$ws" > /dev/null 2>&1

    [ -f "$SEARCH_INDEX" ] || { echo "  FAIL 索引未生成"; FAILED=$((FAILED+1)); return; }
    assert_contains "mcm-meta source=agent evidence=observed" "$(cat "$SEARCH_INDEX")" "索引含 mcm-meta 默认行"
    # header 后紧跟 meta 行
    local first_meta_line
    first_meta_line=$(grep -n 'mcm-meta' "$SEARCH_INDEX" | head -1 | cut -d: -f1)
    local first_header_line
    first_header_line=$(grep -n '^=====' "$SEARCH_INDEX" | head -1 | cut -d: -f1)
    assert_ge "$first_meta_line" "$first_header_line" "meta 行在 header 之后"
    local diff=$((first_meta_line - first_header_line))
    assert_equal "1" "$diff" "meta 行紧邻 header (行 $first_header_line → $first_meta_line)"
}

# ----------------------------------------------------------------------------
# 3b: user/validated 权重 (1.0) 应让相同 BM25 的记忆排名高于 agent/observed (0.595)
# ----------------------------------------------------------------------------
it_evidence_weight_ranks_validated_higher() {
    # 直接构造两个内容相同、仅 source/evidence 不同的记忆
    mkdir -p "$PROJECTS_DIR/tools/evA/chunks" "$PROJECTS_DIR/tools/evB/chunks"
    local body="phase three evidence weighting uniquekeyword zeta"
    {
        echo "---"
        echo "source_file: \"\""
        echo "source: agent"
        echo "evidence: observed"
        echo "---"
        echo ""
        echo "$body"
    } > "$PROJECTS_DIR/tools/evA/chunks/1_x.md"
    {
        echo "---"
        echo "source_file: \"\""
        echo "source: user"
        echo "evidence: validated"
        echo "---"
        echo ""
        echo "$body"
    } > "$PROJECTS_DIR/tools/evB/chunks/1_x.md"

    rebuild_search_index 2>/dev/null

    local result
    result=$(find_relevant_memories "uniquekeyword" 2>/dev/null)
    # 输出格式 "name<TAB>score"；解析两条
    local a_score b_score
    a_score=$(printf '%s\n' "$result" | awk -F'\t' '$1=="evA"{print $2}')
    b_score=$(printf '%s\n' "$result" | awk -F'\t' '$1=="evB"{print $2}')
    [ -n "$a_score" ] && [ -n "$b_score" ] || { echo "  FAIL 未取到分数: a=$a_score b=$b_score"; FAILED=$((FAILED+1)); return; }
    # evB (1.0) 应严格大于 evA (0.595)
    awk -v a="$a_score" -v b="$b_score" 'BEGIN{exit !(b > a)}' \
        && { echo -e "  ${GREEN}PASS${NC} user/validated (b=$b_score) > agent/observed (a=$a_score)"; PASSED=$((PASSED+1)); } \
        || { echo -e "  ${RED}FAIL${NC} 权重未生效: b=$b_score a=$a_score"; FAILED=$((FAILED+1)); }
}

# ----------------------------------------------------------------------------
# 3b: mcmMark 提升 chunk 权重 —— 标注后 frontmatter + 索引 meta + op-log 同步
# ----------------------------------------------------------------------------
it_mcm_mark_promotes_chunk() {
    local ws
    ws=$(_seed_ws)
    bash "$PROJECT_DIR/commands/init.sh" \
        --name "mark-proj" --tags "tools" \
        --description "mark test" --workspace "$ws" > /dev/null 2>&1

    # 标注为 user/validated
    bash "$PROJECT_DIR/commands/mark.sh" "mark-proj" --source user --evidence validated > /dev/null 2>&1

    local chunk="$PROJECTS_DIR/tools/mark-proj/chunks/1_CLAUDE.md"
    assert_contains "source: user" "$(cat "$chunk")" "frontmatter source=user"
    assert_contains "evidence: validated" "$(cat "$chunk")" "frontmatter evidence=validated"

    # 索引 meta 行同步更新
    assert_contains "mcm-meta source=user evidence=validated" "$(cat "$SEARCH_INDEX")" "索引 meta 行更新为 user/validated"

    # op-log 记录 mark
    assert_contains "mark" "$(cat "$PROJECTS_DIR/tools/mark-proj/log.md" 2>/dev/null)" "op-log 含 mark 记录"
}

# ----------------------------------------------------------------------------
# 3b: 旧索引（无 meta 行）向后兼容 —— 默认 0.595 权重，仍可召回
# ----------------------------------------------------------------------------
it_old_index_backward_compatible() {
    mkdir -p "$PROJECTS_DIR/tools/legacy/chunks"
    {
        echo "---"
        echo "source_file: \"\""
        echo "---"
        echo ""
        echo "legacy chunk with no source/evidence fields backward compat token"
    } > "$PROJECTS_DIR/tools/legacy/chunks/1_x.md"
    rebuild_search_index 2>/dev/null
    # 剥离 meta 行（模拟 pre-3.3 索引；legacy chunk 无 frontmatter 字段 → 无 meta 行）
    sed -i '/^<!-- mcm-meta /d' "$SEARCH_INDEX"

    local result
    result=$(find_relevant_memories "backward compat token" 2>/dev/null)
    if printf '%s\n' "$result" | grep -q "legacy"; then
        echo -e "  ${GREEN}PASS${NC} 旧索引格式仍可召回"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC} 旧索引格式召回失败"
        FAILED=$((FAILED + 1))
    fi
}

# ----------------------------------------------------------------------------
IT_LIST=(
    "drift clean memory scores high"        it_drift_clean_memory_high_score
    "drift detects index mismatch"          it_drift_detects_index_mismatch
    "index emits mcm-meta line after header" it_index_emits_meta_line
    "evidence weight ranks validated higher" it_evidence_weight_ranks_validated_higher
    "mcmMark promotes chunk weight"        it_mcm_mark_promotes_chunk
    "old index format backward compatible" it_old_index_backward_compatible
)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_its "Phase 3 评分制 + 证据分层" "${IT_LIST[@]}"
fi
