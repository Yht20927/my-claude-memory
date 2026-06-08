#!/bin/bash
# ============================================================================
# mcmLoad - 加载记忆内容到当前会话上下文 (v2.0)
# ============================================================================
# Usage: mcmLoad <名称> [--layer L1|L2|L3|all] [--global]
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
source "$LIB_DIR/core.sh"

NAME=""
LAYER="all"
IS_GLOBAL=false

# ----------------------------------------------------------------------------
# 参数解析
# ----------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --layer)    LAYER="$2"; shift 2 ;;
            --global)   IS_GLOBAL=true; shift ;;
            --help)     usage "用法: mcmLoad <名称> [--layer L1|L2|L3|all] [--global]" ;;
            *)          NAME="$1"; shift ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# 加载 L1: summary
# ----------------------------------------------------------------------------

load_l1() {
    local memory_path="$1"
    local summary_file="$memory_path/summary.md"

    echo "## L1 — 概览"
    echo ""
    if [ -f "$summary_file" ]; then
        cat "$summary_file"
    else
        echo "（无 summary）"
    fi
    echo ""
}

# ----------------------------------------------------------------------------
# 加载 L2: index
# ----------------------------------------------------------------------------

load_l2() {
    local memory_path="$1"
    local index_file="$memory_path/index.md"

    echo "## L2 — 大纲索引"
    echo ""
    if [ -f "$index_file" ]; then
        cat "$index_file"
    else
        echo "（无 index）"
    fi
    echo ""
}

# ----------------------------------------------------------------------------
# 加载 L3: chunks (跳过 frontmatter)
# ----------------------------------------------------------------------------

load_l3() {
    local memory_path="$1"
    local chunks_dir="$memory_path/chunks"

    echo "## L3 — 浓缩内容"
    echo ""

    if [ ! -d "$chunks_dir" ]; then
        echo "（无 chunks）"
        return
    fi

    for chunk in "$chunks_dir"/*.md; do
        [ -f "$chunk" ] || continue
        local chunk_name=$(basename "$chunk")
        # 提取 frontmatter 中的元信息
        local source=$(grep '^source_file: ' "$chunk" 2>/dev/null | head -1 | sed 's/^source_file: //')
        local last_sync=$(grep '^last_sync: ' "$chunk" 2>/dev/null | head -1 | sed 's/^last_sync: //')

        echo "### $chunk_name"
        if [ -n "$source" ]; then
            echo "**来源**: \`$source\`"
        fi
        if [ -n "$last_sync" ]; then
            echo "**最后同步**: $last_sync"
        fi
        echo ""

        # 输出内容（跳过 YAML frontmatter）
        sed -n '/^---$/,/^---$/!p' "$chunk" | sed '/^---$/d'
        echo ""
        echo "---"
        echo ""
    done
}

# ----------------------------------------------------------------------------
# 主函数
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"

    if [ -z "$NAME" ]; then
        echo "用法: mcmLoad <名称> [--layer L1|L2|L3|all] [--global]"
        exit 1
    fi

    local memory_path
    memory_path=$(find_memory_path "$NAME" "$IS_GLOBAL")

    if [ -z "$memory_path" ]; then
        log "未找到记忆: $NAME"
        exit 1
    fi

    echo "# 记忆: $NAME"
    echo ""

    case "$LAYER" in
        L1)   load_l1 "$memory_path" ;;
        L2)   load_l2 "$memory_path" ;;
        L3)   load_l3 "$memory_path" ;;
        all)
            load_l1 "$memory_path"
            load_l2 "$memory_path"
            load_l3 "$memory_path"
            ;;
        *)
            echo "无效的 layer: $LAYER (可选: L1, L2, L3, all)"
            exit 1
            ;;
    esac

    log "加载完成: $NAME (layer: $LAYER)"
}

main "$@"
