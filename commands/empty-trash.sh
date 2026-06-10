#!/bin/bash
# ============================================================================
# mcmEmptyTrash - 清空回收站 (v2.0)
# ============================================================================
# Usage: mcmEmptyTrash [--force]
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
source "$LIB_DIR/core.sh"

FORCE=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) FORCE=true; shift ;;
            --help)  usage "用法: mcmEmptyTrash [--force]" ;;
            *)       shift ;;
        esac
    done
}

main() {
    parse_args "$@"

    if [ ! -d "$TRASH_DIR" ]; then
        echo "回收站不存在（为空）"
        exit 0
    fi

    local count=$(find "$TRASH_DIR" -maxdepth 1 -type d ! -name ".trash" ! -name ".*" 2>/dev/null | wc -l)
    count=${count// /}

    if [ "$count" -eq 0 ]; then
        echo "回收站为空"
        exit 0
    fi

    if [ "$FORCE" != true ]; then
        echo "确认清空回收站?"
        echo "  将永久删除 $count 个条目"
        echo ""
        echo "输入 'yes' 确认："
        read -r confirm
        if [ "$confirm" != "yes" ]; then
            echo "取消"
            exit 0
        fi
    fi

    empty_trash
    echo "回收站已清空 ($count 个条目被永久删除)"
}

mcm_run_command main "$@"
