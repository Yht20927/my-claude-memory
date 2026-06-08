#!/bin/bash
# ============================================================================
# mcmStatus - 记忆健康总览 (v2.0)
# ============================================================================
# Usage: mcmStatus [--json]
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
source "$LIB_DIR/core.sh"

JSON_OUTPUT=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) JSON_OUTPUT=true; shift ;;
            --help) usage "用法: mcmStatus [--json]" ;;
            *)      shift ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# 统计一个记忆目录的状态
# ----------------------------------------------------------------------------

memory_status() {
    local memory_path="$1"
    local name="$2"
    local tag="$3"

    local summary="存在"
    local hash_status="无"
    local l4_status="N/A"
    local chunk_count=0
    local stale_days=""

    [ -f "$memory_path/summary.md" ] && summary=$(head -1 "$memory_path/summary.md" | sed 's/^# //')
    [ -f "$memory_path/hash.json" ] && hash_status="有"
    [ -d "$memory_path/chunks" ] && chunk_count=$(ls "$memory_path/chunks"/*.md 2>/dev/null | wc -l)

    # L4 健康（仅项目）
    if [ -d "$memory_path/.claude" ]; then
        local l4_result=$(check_l4_health "$memory_path/.claude")
        local valid=$(echo "$l4_result" | cut -d' ' -f1)
        local broken=$(echo "$l4_result" | cut -d' ' -f2)
        l4_status="${valid}v ${broken}b"
    fi

    # 检查是否有陈旧 chunk (超过 30 天未同步)
    if [ -d "$memory_path/chunks" ]; then
        local oldest=$(find "$memory_path/chunks" -name "*.md" -mtime +30 2>/dev/null | wc -l)
        [ "$oldest" -gt 0 ] && stale_days="30+ (${oldest} chunks)"
    fi

    echo "$name|$tag|$summary|$hash_status|$chunk_count|$l4_status|${stale_days:-fresh}"
}

# ----------------------------------------------------------------------------
# 主函数
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"

    local project_count=0
    local global_count=0
    local lines=()

    # 项目记忆统计
    for tag in $(get_project_tags); do
        [ ! -d "$PROJECTS_DIR/$tag" ] && continue
        for dir in "$PROJECTS_DIR/$tag"/*/; do
            [ -d "$dir" ] || continue
            local name=$(basename "$dir")
            lines+=("$(memory_status "$dir" "$name" "$tag")")
            project_count=$((project_count + 1))
        done
    done

    # 全局记忆统计
    for mode in $(get_global_modes); do
        [ ! -d "$GLOBAL_DIR/$mode" ] && continue
        for dir in "$GLOBAL_DIR/$mode"/*/; do
            [ -d "$dir" ] || continue
            local name=$(basename "$dir")
            lines+=("$(memory_status "$dir" "$name" "$mode")")
            global_count=$((global_count + 1))
        done
    done

    if [ "$JSON_OUTPUT" = true ]; then
        echo "{"
        echo "  \"summary\": {"
        echo "    \"project_count\": $project_count,"
        echo "    \"global_count\": $global_count,"
        echo "    \"total\": $((project_count + global_count))"
        echo "  },"
        echo "  \"memories\": ["
        local first=true
        for line in "${lines[@]}"; do
            IFS='|' read -r name tag summary hash_status chunks l4 stale <<< "$line"
            $first || echo ","
            first=false
            echo -n "    {\"name\": \"$name\", \"tag\": \"$tag\", \"summary\": \"$summary\", \"hash\": \"$hash_status\", \"chunks\": $chunks, \"l4\": \"$l4\", \"freshness\": \"$stale\"}"
        done
        echo ""
        echo "  ]"
        echo "}"
        return
    fi

    # 文本输出
    echo ""
    echo "# mcMemory 状态总览"
    echo ""
    echo "| 记忆 | 标签 | 简介 | Hash | Chunks | L4 | 新鲜度 |"
    echo "|------|------|------|------|--------|----|--------|"

    for line in "${lines[@]}"; do
        IFS='|' read -r name tag summary hash_status chunks l4 stale <<< "$line"
        echo "| $name | $tag | $summary | $hash_status | $chunks | $l4 | $stale |"
    done

    echo ""
    echo "**总计**: $project_count 项目记忆, $global_count 个人记忆"
    echo ""

    # 回收站状态
    if [ -d "$TRASH_DIR" ]; then
        local trash_count=$(find "$TRASH_DIR" -maxdepth 1 -type d ! -name ".trash" ! -name ".*" 2>/dev/null | wc -l)
        trash_count=${trash_count// /}
        if [ "$trash_count" -gt 0 ]; then
            echo "回收站: $trash_count 个条目 (运行 mcmEmptyTrash 清空)"
        fi
    fi
}

main "$@"
