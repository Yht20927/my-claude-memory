#!/bin/bash
# ============================================================================
# mcmList - 列出所有已注册记忆 (v2.0)
# ============================================================================
# Usage: mcmList [--json]
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
            --help) usage "用法: mcmList [--json]" ;;
            *)      shift ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# JSON 输出（通过 Python json.dumps 生成有效 JSON）
# ----------------------------------------------------------------------------

json_list() {
    $PYTHON -c "
import json, sys, os

def parse_index(path, group_key):
    items = []
    if not os.path.isfile(path):
        return items
    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if line.startswith('- ['):
                name = line[line.index('[')+1 : line.index(']')]
                group = ''
                if 'path: ' in line:
                    path_part = line[line.index('path: ')+6:].strip()
                    if '/' in path_part:
                        group = path_part.split('/')[0]
                items.append({'name': name, group_key: group})
    return items

result = {
    'projects': parse_index(sys.argv[1], 'tag'),
    'global': parse_index(sys.argv[2], 'mode')
}
print(json.dumps(result, indent=2, ensure_ascii=False))
" "$PROJECTS_DIR/index.md" "$GLOBAL_DIR/index.md" 2>/dev/null
}

# ----------------------------------------------------------------------------
# 文本输出
# ----------------------------------------------------------------------------

text_list_projects() {
    local index_file="$PROJECTS_DIR/index.md"
    echo "## 项目记忆"
    echo ""
    if [ ! -f "$index_file" ]; then
        echo "（暂无）"
        return
    fi
    local current_tag=""
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^## '; then
            echo "$line"
            current_tag="${line#\#\# }"
        elif echo "$line" | grep -qE '^- \['; then
            local name=$(echo "$line" | sed -n 's/^- \[\([^]]*\)\].*/\1/p')
            [ -n "$name" ] && echo "  - $name"
        fi
    done < "$index_file"
}

text_list_global() {
    local index_file="$GLOBAL_DIR/index.md"
    echo ""
    echo "## 个人记忆"
    echo ""
    if [ ! -f "$index_file" ]; then
        echo "（暂无）"
        return
    fi
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^## '; then
            echo "$line"
        elif echo "$line" | grep -qE '^- \['; then
            local name=$(echo "$line" | sed -n 's/^- \[\([^]]*\)\].*/\1/p')
            [ -n "$name" ] && echo "  - $name"
        fi
    done < "$index_file"
}

main() {
    parse_args "$@"

    if [ "$JSON_OUTPUT" = true ]; then
        json_list
    else
        text_list_projects
        text_list_global
    fi
}

main "$@"
