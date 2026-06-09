#!/bin/bash
# ============================================================================
# mcmStatus - 记忆健康总览 (v2.4)
# ----------------------------------------------------------------------------
# v2.4 增强:
#   - 顶部高亮"当前 workspace 绑定的项目记忆"，无绑定时给出 mcmInit 提示
#   - 列出会在新会话自动加载的 auto 全局记忆
#   - 每条记忆显示占位 chunk 数（[待AI补充]）和 stale 状态
#   - 回收站显示总体积，便于决定何时 mcmEmptyTrash
# ============================================================================
# Usage: mcmStatus [--json]
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
source "$LIB_DIR/core.sh"

JSON_OUTPUT=false
WORKSPACE="${MCM_WORKSPACE:-$(pwd)}"

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) JSON_OUTPUT=true; shift ;;
            --workspace) WORKSPACE="$2"; shift 2 ;;
            --help) usage "用法: mcmStatus [--json] [--workspace PATH]" ;;
            *)      shift ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# 统计单个记忆的占位 chunk 数
# ----------------------------------------------------------------------------

count_placeholder_chunks() {
    local memory_path="$1"
    local n=0
    if [ -d "$memory_path/chunks" ]; then
        for chunk in "$memory_path/chunks"/*.md; do
            [ -f "$chunk" ] || continue
            if grep -qF '[待AI补充' "$chunk" 2>/dev/null; then
                n=$((n + 1))
            fi
        done
    fi
    echo "$n"
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
    local placeholder_count=0
    local stale_days=""

    [ -f "$memory_path/summary.md" ] && summary=$(head -1 "$memory_path/summary.md" | sed 's/^# //')
    [ -f "$memory_path/hash.json" ] && hash_status="有"
    [ -d "$memory_path/chunks" ] && chunk_count=$(ls "$memory_path/chunks"/*.md 2>/dev/null | wc -l)
    placeholder_count=$(count_placeholder_chunks "$memory_path")

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
        [ "$oldest" -gt 0 ] && stale_days="30+ (${oldest})"
    fi

    echo "$name|$tag|$summary|$hash_status|$chunk_count|$placeholder_count|$l4_status|${stale_days:-fresh}"
}

# ----------------------------------------------------------------------------
# 当前 workspace 绑定的项目记忆
# ----------------------------------------------------------------------------

current_workspace_binding() {
    local proj_dir
    proj_dir=$(find_project_memory_dir "$WORKSPACE" 2>/dev/null)
    if [ -n "$proj_dir" ]; then
        local tag
        tag=$(basename "$(dirname "$proj_dir")")
        local name
        name=$(basename "$proj_dir")
        echo "$name|$tag|$proj_dir"
    fi
}

# ----------------------------------------------------------------------------
# auto 全局记忆列表（会在新会话自动加载）
# ----------------------------------------------------------------------------

list_auto_memories() {
    [ -d "$GLOBAL_DIR/auto" ] || return
    local d
    for d in "$GLOBAL_DIR/auto"/*/; do
        [ -d "$d" ] || continue
        local name
        name=$(basename "$d")
        local desc=""
        if [ -f "$d/summary.md" ]; then
            desc=$(sed -n '2p' "$d/summary.md" 2>/dev/null | head -c 80)
        fi
        echo "$name|$desc"
    done
}

# ----------------------------------------------------------------------------
# 回收站统计
# ----------------------------------------------------------------------------

trash_stats() {
    [ -d "$TRASH_DIR" ] || { echo "0|0"; return; }
    local count
    count=$(find "$TRASH_DIR" -maxdepth 1 -mindepth 1 -type d ! -name ".*" 2>/dev/null | wc -l)
    count=${count// /}
    local size_bytes
    size_bytes=$(du -sb "$TRASH_DIR" 2>/dev/null | cut -f1)
    size_bytes=${size_bytes:-0}
    echo "$count|$size_bytes"
}

# 把字节数转人类可读
human_bytes() {
    local b="$1"
    $PYTHON -c "
import sys
b = int(sys.argv[1])
for unit in ['B','KB','MB','GB']:
    if b < 1024:
        print(f'{b:.1f}{unit}')
        sys.exit(0)
    b /= 1024
print(f'{b:.1f}TB')
" "$b" 2>/dev/null || echo "${b}B"
}

# ----------------------------------------------------------------------------
# 主函数
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"

    local project_count=0
    local global_count=0
    local total_placeholders=0
    local lines=()

    # 项目记忆统计
    for tag in $(get_project_tags); do
        [ ! -d "$PROJECTS_DIR/$tag" ] && continue
        for dir in "$PROJECTS_DIR/$tag"/*/; do
            [ -d "$dir" ] || continue
            local name=$(basename "$dir")
            local entry
            entry=$(memory_status "$dir" "$name" "$tag")
            lines+=("$entry")
            local ph
            ph=$(echo "$entry" | awk -F'|' '{print $6}')
            total_placeholders=$((total_placeholders + ph))
            project_count=$((project_count + 1))
        done
    done

    # 全局记忆统计
    for mode in $(get_global_modes); do
        [ ! -d "$GLOBAL_DIR/$mode" ] && continue
        for dir in "$GLOBAL_DIR/$mode"/*/; do
            [ -d "$dir" ] || continue
            local name=$(basename "$dir")
            local entry
            entry=$(memory_status "$dir" "$name" "$mode")
            lines+=("$entry")
            local ph
            ph=$(echo "$entry" | awk -F'|' '{print $6}')
            total_placeholders=$((total_placeholders + ph))
            global_count=$((global_count + 1))
        done
    done

    local current_binding
    current_binding=$(current_workspace_binding)

    local auto_list=()
    while IFS= read -r entry; do
        [ -n "$entry" ] && auto_list+=("$entry")
    done < <(list_auto_memories)

    local trash_info
    trash_info=$(trash_stats)
    local trash_count
    trash_count=$(echo "$trash_info" | cut -d'|' -f1)
    local trash_bytes
    trash_bytes=$(echo "$trash_info" | cut -d'|' -f2)

    # ---------- JSON 输出 ----------
    if [ "$JSON_OUTPUT" = true ]; then
        $PYTHON -c "
import json, sys
lines = sys.argv[1].split('\\n') if sys.argv[1] else []
auto = sys.argv[2].split('\\n') if sys.argv[2] else []
binding_raw = sys.argv[3]
data = {
    'workspace': sys.argv[4],
    'binding': None,
    'summary': {
        'project_count': int(sys.argv[5]),
        'global_count': int(sys.argv[6]),
        'total': int(sys.argv[5]) + int(sys.argv[6]),
        'placeholder_chunks': int(sys.argv[7]),
    },
    'auto_memories': [],
    'trash': {
        'count': int(sys.argv[8]),
        'bytes': int(sys.argv[9]),
    },
    'memories': [],
}
if binding_raw:
    parts = binding_raw.split('|')
    data['binding'] = {'name': parts[0], 'tag': parts[1], 'path': parts[2] if len(parts) > 2 else ''}
for entry in auto:
    if not entry:
        continue
    p = entry.split('|', 1)
    data['auto_memories'].append({'name': p[0], 'description': p[1] if len(p) > 1 else ''})
for line in lines:
    if not line:
        continue
    p = line.split('|')
    if len(p) >= 8:
        data['memories'].append({
            'name': p[0], 'tag': p[1], 'summary': p[2], 'hash': p[3],
            'chunks': int(p[4]), 'placeholders': int(p[5]),
            'l4': p[6], 'freshness': p[7],
        })
print(json.dumps(data, indent=2, ensure_ascii=False))
" "$(IFS=$'\n'; echo "${lines[*]}")" \
  "$(IFS=$'\n'; echo "${auto_list[*]}")" \
  "$current_binding" "$WORKSPACE" \
  "$project_count" "$global_count" "$total_placeholders" \
  "$trash_count" "$trash_bytes"
        return
    fi

    # ---------- 文本输出 ----------
    echo ""
    echo "# mcMemory 状态总览"
    echo ""

    # 当前 workspace 绑定
    echo "## 当前 workspace"
    echo ""
    echo "\`$WORKSPACE\`"
    echo ""
    if [ -n "$current_binding" ]; then
        IFS='|' read -r b_name b_tag b_path <<< "$current_binding"
        echo "✓ 绑定项目记忆: \`$b_name\` (tag: $b_tag)"
        echo "  路径: $b_path"
    else
        echo "✗ 未绑定项目记忆"
        echo "  提示: 运行 \`mcmInit\` 在当前目录初始化记忆"
    fi
    echo ""

    # 会自动加载的 auto 记忆
    if [ ${#auto_list[@]} -gt 0 ]; then
        echo "## SessionStart 自动加载"
        echo ""
        echo "新会话开始时以下 auto 全局记忆会被自动注入："
        for entry in "${auto_list[@]}"; do
            IFS='|' read -r a_name a_desc <<< "$entry"
            echo "- \`$a_name\` — ${a_desc:-(无描述)}"
        done
        echo ""
    fi

    # 全部记忆表格
    echo "## 全部记忆"
    echo ""
    echo "| 记忆 | 标签 | 简介 | Hash | Chunks | 占位 | L4 | 新鲜度 |"
    echo "|------|------|------|------|--------|------|----|--------|"

    for line in "${lines[@]}"; do
        IFS='|' read -r name tag summary hash_status chunks placeholders l4 stale <<< "$line"
        # 占位 chunk 高亮
        local ph_cell="$placeholders"
        [ "$placeholders" -gt 0 ] && ph_cell="**$placeholders**"
        echo "| $name | $tag | $summary | $hash_status | $chunks | $ph_cell | $l4 | $stale |"
    done

    echo ""
    echo "**总计**: $project_count 项目记忆, $global_count 个人记忆"

    # 占位 chunk 汇总提示
    if [ "$total_placeholders" -gt 0 ]; then
        echo ""
        echo "⚠ 共 $total_placeholders 个占位 chunk 待 AI 补充："
        echo "  让 AI 读取对应 source_file 并替换 \`[待AI补充：...]\` 为浓缩内容"
        echo "  或运行 \`mcmDoctor\` 查看详细位置"
    fi
    echo ""

    # 回收站状态
    if [ "$trash_count" -gt 0 ]; then
        local human_size
        human_size=$(human_bytes "$trash_bytes")
        echo "## 回收站"
        echo ""
        echo "$trash_count 个条目，占用 $human_size"
        echo "  运行 \`mcmEmptyTrash\` 永久清空"
        echo ""
    fi
}

main "$@"
