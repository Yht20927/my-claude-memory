#!/bin/bash
# ============================================================================
# mcmImport - 从 tar.gz 归档导入记忆 (v2.0)
# ============================================================================
# Usage: mcmImport <文件> [--tags TAGS] [--global]
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
source "$LIB_DIR/core.sh"

FILE=""
TAGS=""
IS_GLOBAL=false

# ----------------------------------------------------------------------------
# 参数解析
# ----------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tags)     TAGS="$2"; shift 2 ;;
            --global)   IS_GLOBAL=true; shift ;;
            --help)     usage "用法: mcmImport <文件> [--tags TAGS] [--global]" ;;
            *)          FILE="$1"; shift ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# 主函数
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"

    if [ -z "$FILE" ]; then
        echo "用法: mcmImport <文件> [--tags TAGS] [--global]"
        exit 1
    fi

    if [ ! -f "$FILE" ]; then
        error "文件不存在: $FILE"
    fi

    # 验证是有效的记忆归档
    local tmpdir=$(mktemp -d)
    tar -xzf "$FILE" -C "$tmpdir" 2>/dev/null
    if [ $? -ne 0 ]; then
        rm -rf "$tmpdir"
        error "不是有效的 tar.gz 归档"
    fi

    # 查找记忆目录
    local memory_dir=""
    for d in "$tmpdir"/*/; do
        if [ -f "$d/summary.md" ]; then
            memory_dir="$d"
            break
        fi
    done

    if [ -z "$memory_dir" ]; then
        rm -rf "$tmpdir"
        error "归档中没有找到有效的记忆 (缺少 summary.md)"
    fi

    local memory_name=$(basename "$memory_dir")

    # 确定目标位置
    if [ -z "$TAGS" ]; then
        TAGS="imported"
    fi
    local primary_tag=$(echo "$TAGS" | cut -d',' -f1 | xargs)

    local dest_dir
    if [ "$IS_GLOBAL" = true ]; then
        mkdir -p "$GLOBAL_DIR/$primary_tag"
        dest_dir="$GLOBAL_DIR/$primary_tag/$memory_name"
    else
        mkdir -p "$PROJECTS_DIR/$primary_tag"
        dest_dir="$PROJECTS_DIR/$primary_tag/$memory_name"
    fi

    if [ -d "$dest_dir" ]; then
        rm -rf "$tmpdir"
        error "目标已存在: $dest_dir (请先删除或重命名)"
    fi

    mv "$memory_dir" "$dest_dir"
    rm -rf "$tmpdir"

    # 更新索引
    if [ "$IS_GLOBAL" = true ]; then
        update_global_index "global" "$primary_tag" "$memory_name" "$dest_dir" "add"
    else
        update_global_index "project" "$primary_tag" "$memory_name" "$dest_dir" "add"
    fi

    # 增量更新搜索索引
    update_search_index "$memory_name" "$dest_dir" "$IS_GLOBAL"

    log "导入成功: $memory_name → $dest_dir"
}

mcm_run_command main "$@"
