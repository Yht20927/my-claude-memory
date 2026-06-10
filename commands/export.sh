#!/bin/bash
# ============================================================================
# mcmExport - 导出记忆为 tar.gz 归档 (v2.0)
# ============================================================================
# Usage: mcmExport <名称> [--output PATH] [--global]
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
source "$LIB_DIR/core.sh"

NAME=""
OUTPUT=""
IS_GLOBAL=false

# ----------------------------------------------------------------------------
# 参数解析
# ----------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output)   OUTPUT="$2"; shift 2 ;;
            --global)   IS_GLOBAL=true; shift ;;
            --help)     usage "用法: mcmExport <名称> [--output PATH] [--global]" ;;
            *)          NAME="$1"; shift ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# 主函数
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"

    if [ -z "$NAME" ]; then
        echo "用法: mcmExport <名称> [--output PATH] [--global]"
        exit 1
    fi

    local memory_path
    memory_path=$(find_memory_path "$NAME" "$IS_GLOBAL")

    if [ -z "$memory_path" ]; then
        log "未找到记忆: $NAME"
        exit 1
    fi

    if [ -z "$OUTPUT" ]; then
        OUTPUT="./${NAME}_memory_$(date '+%Y%m%d_%H%M%S').tar.gz"
    fi

    local parent=$(dirname "$memory_path")
    local dirname=$(basename "$memory_path")

    log "导出记忆: $NAME → $OUTPUT"
    tar -czf "$OUTPUT" -C "$parent" "$dirname"

    if [ $? -eq 0 ]; then
        log "导出成功: $OUTPUT ($(du -h "$OUTPUT" 2>/dev/null | cut -f1 || echo '?'))"
    else
        error "导出失败"
    fi
}

mcm_run_command main "$@"
