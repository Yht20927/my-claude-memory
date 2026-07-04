#!/bin/bash
# ============================================================================
# mcmDoctor - 健康诊断与自动修复 (v2.3+)
# ============================================================================
# 检测并修复历史遗留的数据问题：
#   1. 标签目录名含逗号/特殊字符（早期版本 bug，已在 v2.3+ 的 init/update 修复）
#   2. 占位 chunk 统计
#   3. 失效 L4 链接统计
# 使用 --fix 才会实际执行修复，否则仅报告。
# ----------------------------------------------------------------------------
# Usage: mcmDoctor [--fix] [--json]
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
source "$LIB_DIR/core.sh"
source "$LIB_DIR/inject.sh"   # v3.2: doctor canary 用 find_relevant_memories 端到端验证搜索

DO_FIX=false
JSON_OUTPUT=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fix)   DO_FIX=true; shift ;;
            --json)  JSON_OUTPUT=true; shift ;;
            --help)  usage "用法: mcmDoctor [--fix] [--json]" ;;
            *)       shift ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# 检测脏 tag 目录（含逗号/空格等无效字符）
# ----------------------------------------------------------------------------

scan_dirty_tags() {
    local base_dir="$1"
    [ -d "$base_dir" ] || return

    local d
    for d in "$base_dir"/*/; do
        [ -d "$d" ] || continue
        local tag
        tag=$(basename "$d")
        # 含逗号、空格或其他非 [a-zA-Z0-9_-] 字符判定为脏
        if [[ "$tag" =~ [^a-zA-Z0-9_-] ]]; then
            echo "$tag"
        fi
    done
}

# ----------------------------------------------------------------------------
# 迁移脏 tag 目录下的记忆到清洗后的主标签目录
# ----------------------------------------------------------------------------

migrate_dirty_tag() {
    local base_dir="$1"
    local dirty_tag="$2"
    local scope_label="$3"  # "project" or "global"

    local clean_tag
    clean_tag=$(parse_primary_tag "$dirty_tag" "tools")
    local src_dir="$base_dir/$dirty_tag"
    local dst_dir="$base_dir/$clean_tag"

    if [ "$src_dir" = "$dst_dir" ]; then
        return 0
    fi

    mkdir -p "$dst_dir"

    local mem_dir
    for mem_dir in "$src_dir"/*/; do
        [ -d "$mem_dir" ] || continue
        local mem_name
        mem_name=$(basename "$mem_dir")
        local target="$dst_dir/$mem_name"

        if [ -e "$target" ]; then
            log "  [skip] $scope_label/$mem_name 已存在于 $clean_tag/，留待人工处理"
            continue
        fi

        if [ "$DO_FIX" = true ]; then
            mv "$mem_dir" "$target"
            log "  [moved] $dirty_tag/$mem_name → $clean_tag/$mem_name"

            # 同步全局索引中的 path 字段
            local index_file
            if [ "$scope_label" = "project" ]; then
                index_file="$PROJECTS_DIR/index.md"
            else
                index_file="$GLOBAL_DIR/index.md"
            fi
            if [ -f "$index_file" ]; then
                local safe_name
                safe_name=$(sed_escape "$mem_name")
                local safe_dirty
                safe_dirty=$(sed_escape "$dirty_tag")
                local safe_clean
                safe_clean=$(sed_escape "$clean_tag")
                # 替换该条目的 path 中的 tag 段
                sed_i "/\[$safe_name\]/s|path: $safe_dirty/|path: $safe_clean/|" "$index_file"
            fi
        else
            log "  [dry-run] 将移动: $dirty_tag/$mem_name → $clean_tag/$mem_name"
        fi
    done

    # 如果源目录已空则删除
    if [ "$DO_FIX" = true ] && [ -z "$(ls -A "$src_dir" 2>/dev/null)" ]; then
        rmdir "$src_dir" 2>/dev/null || true
    fi
}

# ----------------------------------------------------------------------------
# 统计占位 chunk
# ----------------------------------------------------------------------------

count_placeholders() {
    local base_dir="$1"
    [ -d "$base_dir" ] || { echo 0; return; }

    local total=0
    while IFS= read -r -d '' chunk; do
        if grep -qF '[待AI补充' "$chunk" 2>/dev/null; then
            total=$((total + 1))
        fi
    done < <(find "$base_dir" -name "*.md" -path "*/chunks/*" -print0 2>/dev/null)
    echo "$total"
}

# ----------------------------------------------------------------------------
# v3.2 Phase 2: Canary 探针 — 端到端验证搜索管线
# ----------------------------------------------------------------------------
# 在 $GLOBAL_DIR/.canary/ 隐藏 dotdir 下放一个含唯一 token 的探针记忆：
#   - get_global_modes() 用 */ 扫描，跳过 dotdir → 不污染 mcmStatus
#   - mcmList 读 index.md，canary 不入 index → 不污染 mcmList
#   - rebuild_search_index 的 find 会扫到 → 进搜索索引 → 可被 find_relevant_memories 命中
# doctor 确保 canary 存在+已索引，然后查 token 断言命中。
# 未命中 = 索引损坏 / BM25 管线异常 → 建议重建索引。
CANARY_TOKEN="__MCM_CANARY_v3_2_TOKEN__"
CANARY_MEM_NAME="_mcm_canary"
CANARY_MEM_DIR="$GLOBAL_DIR/.canary/$CANARY_MEM_NAME"

ensure_canary() {
    mkdir -p "$CANARY_MEM_DIR/chunks"
    if [ ! -f "$CANARY_MEM_DIR/summary.md" ]; then
        printf '# %s\nmcmDoctor 端到端探针（勿删；可被 mcmDoctor 重建）\n' "$CANARY_MEM_NAME" \
            > "$CANARY_MEM_DIR/summary.md"
    fi
    local chunk="$CANARY_MEM_DIR/chunks/1_canary.md"
    if [ ! -f "$chunk" ] || ! grep -qF "$CANARY_TOKEN" "$chunk" 2>/dev/null; then
        cat > "$chunk" <<EOF
---
source_file: ""
created: $(date '+%Y-%m-%d')
type: canary
source: agent
evidence: validated
---

# canary

$CANARY_TOKEN
EOF
    fi
    # 确保探针在搜索索引中（幂等：remove + append）
    update_search_index "$CANARY_MEM_NAME" "$CANARY_MEM_DIR" true
}

# 返回 0 = canary 命中（管线正常）；1 = 未命中（索引可能损坏）
check_canary() {
    ensure_canary
    local result
    result=$(find_relevant_memories "$CANARY_TOKEN" 2>/dev/null)
    if printf '%s' "$result" | grep -qF "$CANARY_MEM_NAME"; then
        return 0
    else
        return 1
    fi
}

# ----------------------------------------------------------------------------
# 主函数
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"

    local dirty_project_tags=()
    local dirty_global_tags=()
    while IFS= read -r t; do
        [ -n "$t" ] && dirty_project_tags+=("$t")
    done < <(scan_dirty_tags "$PROJECTS_DIR")
    while IFS= read -r t; do
        [ -n "$t" ] && dirty_global_tags+=("$t")
    done < <(scan_dirty_tags "$GLOBAL_DIR")

    local project_placeholders
    project_placeholders=$(count_placeholders "$PROJECTS_DIR")
    local global_placeholders
    global_placeholders=$(count_placeholders "$GLOBAL_DIR")

    # v3.2: canary 端到端搜索管线验证
    local canary_ok="false"
    if check_canary; then
        canary_ok="true"
    fi

    if [ "$JSON_OUTPUT" = true ]; then
        $PYTHON -c "
import json, sys
data = {
    'dirty_project_tags': sys.argv[1].split('|') if sys.argv[1] else [],
    'dirty_global_tags': sys.argv[2].split('|') if sys.argv[2] else [],
    'placeholder_chunks': {
        'project': int(sys.argv[3]),
        'global': int(sys.argv[4]),
    },
    'fix_applied': sys.argv[5] == 'true',
    'canary': {'ok': sys.argv[6] == 'true'},
}
print(json.dumps(data, indent=2, ensure_ascii=False))
" "$(IFS='|'; echo "${dirty_project_tags[*]}")" \
  "$(IFS='|'; echo "${dirty_global_tags[*]}")" \
  "$project_placeholders" "$global_placeholders" "$DO_FIX" "$canary_ok"
        return
    fi

    echo ""
    echo "## mcmDoctor 健康检查报告"
    echo ""

    # 检查项 1: 脏 tag 目录
    if [ ${#dirty_project_tags[@]} -eq 0 ] && [ ${#dirty_global_tags[@]} -eq 0 ]; then
        echo "✓ 标签目录命名规范，无脏数据"
    else
        echo "✗ 发现含特殊字符的标签目录:"
        for t in "${dirty_project_tags[@]}"; do
            local clean
            clean=$(parse_primary_tag "$t" "tools")
            echo "  - projects/$t → 建议迁移为 projects/$clean"
        done
        for t in "${dirty_global_tags[@]}"; do
            local clean
            clean=$(parse_primary_tag "$t" "auto")
            echo "  - global/$t → 建议迁移为 global/$clean"
        done

        if [ "$DO_FIX" = true ]; then
            echo ""
            echo "执行迁移..."
            local lock_token
            lock_token=$(acquire_lock "doctor")
            mcm_on_exit "release_lock 'doctor' '$lock_token'"
            for t in "${dirty_project_tags[@]}"; do
                migrate_dirty_tag "$PROJECTS_DIR" "$t" "project"
            done
            for t in "${dirty_global_tags[@]}"; do
                migrate_dirty_tag "$GLOBAL_DIR" "$t" "global"
            done
            release_lock "doctor" "$lock_token"
            mcm_clear_exit_handlers

            # 迁移完成后重建搜索索引
            rebuild_search_index
            echo "✓ 迁移完成，搜索索引已重建"
        else
            echo ""
            echo "  提示: 加 --fix 参数执行实际迁移"
        fi
    fi

    echo ""

    # 检查项 2: 占位 chunk
    local total_placeholders=$((project_placeholders + global_placeholders))
    if [ "$total_placeholders" -eq 0 ]; then
        echo "✓ 无占位 chunk（所有 L3 chunk 均已浓缩）"
    else
        echo "⚠ 发现 $total_placeholders 个占位 chunk 待 AI 补充:"
        echo "  - project: $project_placeholders"
        echo "  - global:  $global_placeholders"
        echo "  提示: 让 AI 读取对应 source_file 并替换 [待AI补充：...] 占位符"
    fi

    echo ""
    # 检查项 3 (v3.2): canary 端到端搜索管线验证
    if [ "$canary_ok" = true ]; then
        echo "✓ 搜索管线正常（canary 命中）"
    else
        echo "✗ 搜索管线异常：canary 未被命中"
        echo "  索引可能损坏。建议: 运行 mcmSync 或重建索引"
    fi
}

mcm_run_command main "$@"
