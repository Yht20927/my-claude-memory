#!/bin/bash
# ============================================================================
# mcmSearch - 全文搜索记忆 (v2.0)
# ============================================================================
# Usage: mcmSearch <关键词> [--expand] [--global] [--json]
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
source "$LIB_DIR/core.sh"

KEYWORD=""
EXPAND=false
IS_GLOBAL=false
SCOPE="project"
JSON_OUTPUT=false

# ----------------------------------------------------------------------------
# 参数解析
# ----------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --expand)   EXPAND=true; shift ;;
            --global)   IS_GLOBAL=true; SCOPE="global"; shift ;;
            --json)     JSON_OUTPUT=true; shift ;;
            --help)     usage "用法: mcmSearch <关键词> [--expand] [--global] [--json]" ;;
            *)          KEYWORD="$1"; shift ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# Step 1: 搜索（优先使用索引文件）
# ----------------------------------------------------------------------------

step1_search() {
    local keyword="$1"

    # 优先使用合并索引（更快）— 返回匹配的 chunk 文件路径
    if [ -f "$SEARCH_INDEX" ] && [ -s "$SEARCH_INDEX" ]; then
        # 从索引中提取匹配行所属的 chunk，解析为文件路径
        $PYTHON -c "
import sys, re, os

keyword = sys.argv[1].lower()
scope = sys.argv[2]
index_file = sys.argv[3]
projects_dir = sys.argv[4]
global_dir = sys.argv[5]

current_mem = ''
current_chunk = ''
is_global = False
matched_chunks = set()

with open(index_file, 'r') as f:
    for line in f:
        m = re.match(r'^===== (\[global\] )?(.+?) / (.+?) =====$', line.strip())
        if m:
            is_global = bool(m.group(1))
            current_mem = m.group(2).strip()
            current_chunk = m.group(3).strip()
        elif keyword in line.lower() and current_mem and current_chunk:
            if scope == 'global' and not is_global:
                continue
            if scope == 'project' and is_global:
                continue
            if is_global:
                path = os.path.join(global_dir, current_mem, 'chunks', current_chunk)
            else:
                # project: 需要查找 tag 目录
                for tag in os.listdir(projects_dir) if os.path.isdir(projects_dir) else []:
                    candidate = os.path.join(projects_dir, tag, current_mem, 'chunks', current_chunk)
                    if os.path.isfile(candidate):
                        path = candidate
                        break
                else:
                    path = ''
            if path and os.path.isfile(path):
                matched_chunks.add(path)

for p in sorted(matched_chunks):
    print(p)
" "$keyword" "$SCOPE" "$SEARCH_INDEX" "$PROJECTS_DIR" "$GLOBAL_DIR" 2>/dev/null
        return
    fi

    # 回退到遍历 chunks
    if [ "$SCOPE" = "global" ]; then
        local search_dirs=()
        for mode in $(get_global_modes); do
            [ -d "$GLOBAL_DIR/$mode" ] && search_dirs+=("$GLOBAL_DIR/$mode")
        done
    else
        local search_dirs=()
        for tag in $(get_project_tags); do
            [ -d "$PROJECTS_DIR/$tag" ] && search_dirs+=("$PROJECTS_DIR/$tag")
        done
    fi

    for dir in "${search_dirs[@]}"; do
        [ ! -d "$dir" ] && continue
        find "$dir" -name "*.md" -path "*/chunks/*" -exec grep -il "$keyword" {} \; 2>/dev/null
    done
}

# ----------------------------------------------------------------------------
# Step 2: 格式化输出
# ----------------------------------------------------------------------------

step2_output_results() {
    local keyword="$1"
    shift
    local results=("$@")

    if [ "$JSON_OUTPUT" = true ]; then
        # 通过 Python json.dumps 生成有效 JSON
        if [ ${#results[@]} -eq 0 ]; then
            echo "[]"
            return
        fi
        printf '%s\n' "${results[@]}" | $PYTHON -c "
import json, sys, os
keyword = sys.argv[1]
items = []
for path in sys.stdin:
    path = path.strip()
    if not path or not os.path.isfile(path):
        continue
    project_name = os.path.basename(os.path.dirname(os.path.dirname(path)))
    chunk_name = os.path.basename(path)
    match = ''
    try:
        with open(path, 'r') as f:
            for line in f:
                if keyword.lower() in line.lower():
                    match = line.strip()
                    break
    except:
        pass
    items.append({'project': project_name, 'chunk': chunk_name, 'match': match})
print(json.dumps(items, indent=2, ensure_ascii=False))
" "$keyword" 2>/dev/null
        return
    fi

    echo ""
    echo "## 搜索结果：\"$keyword\""
    echo ""

    if [ ${#results[@]} -eq 0 ]; then
        echo "未找到匹配结果"
        return
    fi

    for chunk in "${results[@]}"; do
        [ ! -f "$chunk" ] && continue
        local project_name=$(basename "$(dirname "$(dirname "$chunk")")")
        local chunk_name=$(basename "$chunk")

        echo "### [$project_name]"
        echo "**来源**: \`$chunk_name\`"
        echo "**匹配片段**:"

        if [ "$EXPAND" = true ]; then
            echo ""
            # 跳过 frontmatter，输出内容
            sed -n '/^---$/,/^---$/!p' "$chunk" | sed '/^---$/d'
        else
            local match=$(grep -m1 -i "$keyword" "$chunk" 2>/dev/null || echo "...")
            match=$(echo "$match" | sed 's/^> *//')
            echo "> $match"
        fi
        echo ""
        echo "---"
    done
}

# ----------------------------------------------------------------------------
# 主函数
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"

    if [ -z "$KEYWORD" ]; then
        echo "用法: mcmSearch <关键词> [--expand] [--global] [--json]"
        exit 1
    fi

    log "搜索关键词: $KEYWORD (scope: $SCOPE, expand: $EXPAND)"

    local matched_chunks=()
    while IFS= read -r chunk; do
        [ -n "$chunk" ] && matched_chunks+=("$chunk")
    done < <(step1_search "$KEYWORD")

    step2_output_results "$KEYWORD" "${matched_chunks[@]}"

    log "搜索完成，找到 ${#matched_chunks[@]} 个匹配"
}

main "$@"
