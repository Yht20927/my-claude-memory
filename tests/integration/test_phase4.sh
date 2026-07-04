#!/bin/bash
# ============================================================================
# 集成测试 7: Phase 4 命令覆盖（search/update/delete/restore/load/journal）(v3.4)
# ----------------------------------------------------------------------------
# 补 8 个无专门集成测试的命令：search / update --tags / delete / restore /
# empty-trash / load / journal / inject-log。覆盖核心用户路径与回归保护。
# ============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
source "$PROJECT_DIR/lib/core.sh"
source "$PROJECT_DIR/lib/inject.sh"

_seed_ws() {
    local ws="$INT_FIXTURE_DIR/p4-ws"
    mkdir -p "$ws"
    ( cd "$ws" && git init -q && git config user.email t@x && git config user.name t )
    cat > "$ws/CLAUDE.md" <<'EOF'
# P4 Project
## Architecture
search and command coverage tests.
## Decisions
use bm25 ranking everywhere.
EOF
    echo "$ws"
}

# 用真实内容替换占位 chunk（让 search/load 有非占位内容可测）
# 注意：必须随后 update_search_index，否则索引仍是占位内容（sync 不重建未变源的索引）
_fill_chunk() {
    local mem_dir="$1" content="$2"
    cat > "$mem_dir/chunks/1_CLAUDE.md" <<EOF
---
source_file: ""
source: agent
evidence: observed
---
$content
EOF
    local name
    name=$(basename "$mem_dir")
    update_search_index "$name" "$mem_dir" false 2>/dev/null
}

# ----------------------------------------------------------------------------
# mcmSearch: 基础召回 + --expand + --json
# ----------------------------------------------------------------------------
it_search_finds_matches() {
    local ws
    ws=$(_seed_ws)
    bash "$PROJECT_DIR/commands/init.sh" --name "srch-proj" --tags "tools" \
        --description "search test" --workspace "$ws" > /dev/null 2>&1
    _fill_chunk "$PROJECTS_DIR/tools/srch-proj" "bm25 ranking marker for search coverage"

    local out
    out=$(bash "$PROJECT_DIR/commands/search.sh" "marker" 2>/dev/null)
    assert_contains "### [srch-proj]" "$out" "search 命中并显示结果段头"
    assert_contains "ranking marker for search coverage" "$out" "search 显示匹配片段"

    # --expand 输出 chunk 正文（跳过 frontmatter）
    local exp
    exp=$(bash "$PROJECT_DIR/commands/search.sh" "marker" --expand 2>/dev/null)
    assert_contains "ranking marker for search coverage" "$exp" "search --expand 输出正文"

    # --json 含 project/chunk 字段
    local js
    js=$(bash "$PROJECT_DIR/commands/search.sh" "marker" --json 2>/dev/null)
    assert_contains '"chunk"' "$js" "search --json 含 chunk 字段"
    assert_contains "srch-proj" "$js" "search --json 含 project"

    # 无匹配
    local nomatch
    nomatch=$(bash "$PROJECT_DIR/commands/search.sh" "zzznomatch" 2>/dev/null)
    assert_contains "未找到匹配结果" "$nomatch" "search 无匹配时提示"
}

# ----------------------------------------------------------------------------
# mcmSearch --score: user/validated 排在 agent/observed 之前
# ----------------------------------------------------------------------------
it_search_score_ranks_validated_higher() {
    mkdir -p "$PROJECTS_DIR/tools/sA/chunks" "$PROJECTS_DIR/tools/sB/chunks"
    local body="rankfeature alpha beta gamma delta"
    {
        echo "---"; echo "source_file: \"\""; echo "source: agent"; echo "evidence: observed"; echo "---"
        echo "$body"
    } > "$PROJECTS_DIR/tools/sA/chunks/1_x.md"
    {
        echo "---"; echo "source_file: \"\""; echo "source: user"; echo "evidence: validated"; echo "---"
        echo "$body"
    } > "$PROJECTS_DIR/tools/sB/chunks/1_x.md"
    rebuild_search_index 2>/dev/null

    local out
    out=$(bash "$PROJECT_DIR/commands/search.sh" "rankfeature" --score 2>/dev/null)
    # 解析两个记忆的分数
    local a_score b_score
    a_score=$(printf '%s' "$out" | grep -F '[score=' | grep 'sA' | grep -oE 'score=[0-9.]+' | grep -oE '[0-9.]+')
    b_score=$(printf '%s' "$out" | grep -F '[score=' | grep 'sB' | grep -oE 'score=[0-9.]+' | grep -oE '[0-9.]+')
    assert_contains "score=" "$out" "search --score 显示分数标签"
    awk -v a="$a_score" -v b="$b_score" 'BEGIN{exit !(b > a)}' \
        && { echo -e "  ${GREEN}PASS${NC} sB($b_score) 排在 sA($a_score) 之前"; PASSED=$((PASSED+1)); } \
        || { echo -e "  ${RED}FAIL${NC} 评分排序异常: sB=$b_score sA=$a_score"; FAILED=$((FAILED+1)); }

    # --score --json 含 score 字段
    local js
    js=$(bash "$PROJECT_DIR/commands/search.sh" "rankfeature" --score --json 2>/dev/null)
    assert_contains '"score"' "$js" "search --score --json 含 score 字段"
}

# ----------------------------------------------------------------------------
# mcmUpdate --tags: 标签变更应物理移动目录到新标签分组
# ----------------------------------------------------------------------------
it_update_tags_migrates_directory() {
    local ws
    ws=$(_seed_ws)
    bash "$PROJECT_DIR/commands/init.sh" --name "tagproj" --tags "tools" \
        --description "tag migration" --workspace "$ws" > /dev/null 2>&1
    assert_file_exists "$PROJECTS_DIR/tools/tagproj/summary.md" "迁移前在 tools 下"

    bash "$PROJECT_DIR/commands/update.sh" "tagproj" --tags "mobile" > /dev/null 2>&1

    assert_file_exists "$PROJECTS_DIR/mobile/tagproj/summary.md" "迁移后在 mobile 下"
    if [ ! -d "$PROJECTS_DIR/tools/tagproj" ]; then
        echo -e "  ${GREEN}PASS${NC} 旧 tools/tagproj 已移除"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC} 旧 tools/tagproj 仍存在"
        FAILED=$((FAILED + 1))
    fi
}

# ----------------------------------------------------------------------------
# mcmDelete → mcmRestore → mcmEmptyTrash 完整回收站生命周期
# ----------------------------------------------------------------------------
it_delete_restore_empty_trash_lifecycle() {
    local ws
    ws=$(_seed_ws)
    bash "$PROJECT_DIR/commands/init.sh" --name "trashproj" --tags "tools" \
        --description "trash test" --workspace "$ws" > /dev/null 2>&1

    # delete → 进回收站（条目名带时间戳：trashproj_<ts>_<ns>）
    bash "$PROJECT_DIR/commands/delete.sh" "trashproj" --force > /dev/null 2>&1
    local entry
    entry=$(find "$TRASH_DIR" -maxdepth 1 -type d -name "trashproj_*" 2>/dev/null | head -1 | xargs basename 2>/dev/null)
    if [ -n "$entry" ]; then
        echo -e "  ${GREEN}PASS${NC} delete 创建回收站条目"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC} delete 未创建回收站条目"
        FAILED=$((FAILED + 1))
    fi
    assert_file_exists "$TRASH_DIR/.${entry}.origin" "delete 写 .origin 标记"
    if [ ! -d "$PROJECTS_DIR/tools/trashproj" ]; then
        echo -e "  ${GREEN}PASS${NC} delete 移走原目录"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC} delete 未移走原目录"
        FAILED=$((FAILED + 1))
    fi

    # restore → 回到原位（用完整条目名）
    bash "$PROJECT_DIR/commands/restore.sh" "$entry" > /dev/null 2>&1
    assert_file_exists "$PROJECTS_DIR/tools/trashproj/summary.md" "restore 恢复 summary.md"

    # 再次 delete + empty-trash → 永久清除
    bash "$PROJECT_DIR/commands/delete.sh" "trashproj" --force > /dev/null 2>&1
    bash "$PROJECT_DIR/commands/empty-trash.sh" --force > /dev/null 2>&1
    if [ ! -f "$TRASH_DIR/.trashproj.origin" ] && ! find "$TRASH_DIR" -maxdepth 1 -name "trashproj_*" 2>/dev/null | grep -q .; then
        echo -e "  ${GREEN}PASS${NC} empty-trash 永久清空回收站"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC} empty-trash 后回收站仍有残留"
        FAILED=$((FAILED + 1))
    fi
}

# ----------------------------------------------------------------------------
# mcmLoad: L1 输出 summary，L3 输出 chunk 内容
# ----------------------------------------------------------------------------
it_load_outputs_layers() {
    local ws
    ws=$(_seed_ws)
    bash "$PROJECT_DIR/commands/init.sh" --name "loadproj" --tags "tools" \
        --description "load test memory" --workspace "$ws" > /dev/null 2>&1
    _fill_chunk "$PROJECTS_DIR/tools/loadproj" "loadtest marker content for L3"

    local l1
    l1=$(bash "$PROJECT_DIR/commands/load.sh" "loadproj" --layer L1 2>/dev/null)
    assert_contains "loadproj" "$l1" "load L1 含记忆名"
    assert_contains "load test memory" "$l1" "load L1 含 summary 描述"

    local l3
    l3=$(bash "$PROJECT_DIR/commands/load.sh" "loadproj" --layer L3 2>/dev/null)
    assert_contains "loadtest marker content" "$l3" "load L3 输出 chunk 正文"
}

# ----------------------------------------------------------------------------
# mcmJournal 写 session_notes.md + mcmInjectLog 展示注入事件
# ----------------------------------------------------------------------------
it_journal_and_inject_log() {
    # v3.5: inject.sh 已惰性求值（INJECT_STATE_DIR 等在调用时读 $MEMORY_BASE），
    # 无需重 source —— cooldown 写到 fixture 而非 $HOME，无跨运行 flake。
    local ws
    ws=$(_seed_ws)
    bash "$PROJECT_DIR/commands/init.sh" --name "jourproj" --tags "tools" \
        --description "journal test" --workspace "$ws" > /dev/null 2>&1

    # journal 追加会话笔记到 workspace/.claude/session_notes.md
    bash "$PROJECT_DIR/commands/journal.sh" --workspace "$ws" "discovered journal hook flow" > /dev/null 2>&1
    local notes="$ws/.claude/session_notes.md"
    assert_file_exists "$notes" "journal 创建 session_notes.md"
    assert_contains "discovered journal hook flow" "$(cat "$notes")" "journal 写入笔记内容"

    # 触发一次 prompt_submit 注入事件（sourced inject.sh 已在文件顶部加载）
    : > "$MCM_EVENTS_FILE"
    prompt_submit_inject "journal hook flow architecture" > /dev/null 2>&1

    # inject-log 应能展示该事件
    local log_out
    log_out=$(bash "$PROJECT_DIR/commands/inject-log.sh" 2>/dev/null)
    assert_not_contains "注入日志为空" "$log_out" "inject-log 非空（有注入事件）"

    local log_json
    log_json=$(bash "$PROJECT_DIR/commands/inject-log.sh" --json 2>/dev/null)
    assert_contains "prompt_submit" "$log_json" "inject-log --json 含 prompt_submit 事件"
}

# ----------------------------------------------------------------------------
IT_LIST=(
    "mcmSearch finds matches + expand + json"      it_search_finds_matches
    "mcmSearch --score ranks validated higher"     it_search_score_ranks_validated_higher
    "mcmUpdate --tags migrates directory"          it_update_tags_migrates_directory
    "delete→restore→empty-trash lifecycle"         it_delete_restore_empty_trash_lifecycle
    "mcmLoad outputs L1 + L3"                       it_load_outputs_layers
    "mcmJournal + mcmInjectLog"                    it_journal_and_inject_log
)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_its "Phase 4 命令覆盖" "${IT_LIST[@]}"
fi
