#!/bin/bash
# ============================================================================
# mcmSearch - 全文搜索记忆 (v3.4 — 支持 BM25 评分排序)
# ============================================================================
# Usage: mcmSearch <关键词> [--expand] [--global] [--json] [--score]
#   --score  v3.4: 按 BM25×权重 评分排序结果并显示分数（复用注入评分管线）
# ============================================================================
# v3.4: --score 开关
#   - 复用 lib/inject.sh 的 find_relevant_memories（BM25 + source×evidence 权重）
#   - 候选 chunk 仍按子串匹配收集（保持原有召回语义），仅排序与展示改为评分
#   - 默认不开 --score → 行为与 v3.3 完全一致（opt-in，零回归）
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
source "$LIB_DIR/core.sh"
source "$LIB_DIR/inject.sh"   # v3.4: find_relevant_memories + extract_keywords

KEYWORD=""
EXPAND=false
IS_GLOBAL=false
SCOPE="project"
JSON_OUTPUT=false
SHOW_SCORE=false

# ----------------------------------------------------------------------------
# 参数解析
# ----------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --expand)   EXPAND=true; shift ;;
            --global)   IS_GLOBAL=true; SCOPE="global"; shift ;;
            --json)     JSON_OUTPUT=true; shift ;;
            --score)    SHOW_SCORE=true; shift ;;
            --scope)    SCOPE="$2"; [ "$2" = "user" ] && SCOPE="global"; shift 2 ;;
            --help)     usage "用法: mcmSearch <关键词> [--expand] [--global] [--json] [--score]" ;;
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
# v3.4: 按 BM25×权重 评分排序候选 chunk
# ----------------------------------------------------------------------------
# 候选 chunk 仍由 step1_search 子串匹配收集；此处仅负责排序与打分。
# 复用 find_relevant_memories（per memory 的 max weight），chunk 取其所属记忆的分数。
# 输出 "score<TAB>chunk_path" 每行一条，按分数降序；无分数的排末尾。
# ----------------------------------------------------------------------------
rank_chunks_by_score() {
    local keyword="$1"
    shift
    local -a chunks=("$@")

    # 提取关键词并查记忆分数（subshell 隔离 MAX_INJECT_MEMORIES 改动）
    declare -A mem_score=()
    if [ ${#chunks[@]} -gt 0 ]; then
        local score_lines
        score_lines=$(
            local kws=()
            local kw
            while IFS= read -r kw; do
                [ -n "$kw" ] && kws+=("$kw")
            done < <(extract_keywords "$keyword")
            if [ ${#kws[@]} -gt 0 ]; then
                MAX_INJECT_MEMORIES=9999 find_relevant_memories "${kws[@]}" 2>/dev/null
            fi
        )
        local mem score
        while IFS=$'\t' read -r mem score; do
            [ -n "$mem" ] && mem_score["$mem"]="${score:-0}"
        done <<< "$score_lines"
    fi

    # 每个 chunk 映射到其记忆分数，输出 "score<TAB>path" 并降序排序
    local chunk mem score
    for chunk in "${chunks[@]}"; do
        mem=$(basename "$(dirname "$(dirname "$chunk")")")
        score="${mem_score[$mem]:-0}"
        printf '%s\t%s\n' "$score" "$chunk"
    done | sort -t$'\t' -k1,1 -rn
}

# ----------------------------------------------------------------------------
# Step 2: 格式化输出
# ----------------------------------------------------------------------------

step2_output_results() {
    local keyword="$1"
    shift
    # 入参：无 --score 时为 chunk_path 列表；有 --score 时为 "score<TAB>path" 列表
    local -a rows=("$@")

    if [ "$JSON_OUTPUT" = true ]; then
        if [ ${#rows[@]} -eq 0 ]; then
            echo "[]"
            return
        fi
        # 把 "score<TAB>path" 或裸 path 统一成 stdin 喂给 Python
        printf '%s\n' "${rows[@]}" | $PYTHON -c "
import json, sys, os
keyword = sys.argv[1]
show_score = sys.argv[2] == 'true'
items = []
for raw in sys.stdin:
    raw = raw.rstrip('\n')
    if not raw:
        continue
    if '\t' in raw:
        score, path = raw.split('\t', 1)
    else:
        score, path = '', raw
    if not os.path.isfile(path):
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
    item = {'project': project_name, 'chunk': chunk_name, 'match': match}
    if show_score:
        try:
            item['score'] = round(float(score), 4)
        except:
            item['score'] = 0.0
    items.append(item)
print(json.dumps(items, indent=2, ensure_ascii=False))
" "$keyword" "$SHOW_SCORE" 2>/dev/null
        return
    fi

    echo ""
    echo "## 搜索结果：\"$keyword\""
    echo ""

    if [ ${#rows[@]} -eq 0 ]; then
        echo "未找到匹配结果"
        return
    fi

    local row score chunk
    for row in "${rows[@]}"; do
        if [ "$SHOW_SCORE" = true ]; then
            score="${row%%$'\t'*}"
            chunk="${row#*$'\t'}"
        else
            score=""
            chunk="$row"
        fi
        [ ! -f "$chunk" ] && continue
        local project_name=$(basename "$(dirname "$(dirname "$chunk")")")
        local chunk_name=$(basename "$chunk")

        local score_tag=""
        [ "$SHOW_SCORE" = true ] && score_tag=" [score=$score]"

        echo "### [$project_name]$score_tag"
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
        echo "用法: mcmSearch <关键词> [--expand] [--global] [--json] [--score]"
        exit 1
    fi

    log "搜索关键词: $KEYWORD (scope: $SCOPE, expand: $EXPAND, score: $SHOW_SCORE)"

    local matched_chunks=()
    while IFS= read -r chunk; do
        [ -n "$chunk" ] && matched_chunks+=("$chunk")
    done < <(step1_search "$KEYWORD")

    # v3.4: --score 时按 BM25×权重 排序
    local -a output_rows=()
    if [ "$SHOW_SCORE" = true ] && [ ${#matched_chunks[@]} -gt 0 ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && output_rows+=("$line")
        done < <(rank_chunks_by_score "$KEYWORD" "${matched_chunks[@]}")
    else
        output_rows=("${matched_chunks[@]}")
    fi

    step2_output_results "$KEYWORD" "${output_rows[@]}"

    log "搜索完成，找到 ${#matched_chunks[@]} 个匹配"
}

mcm_run_command main "$@"
