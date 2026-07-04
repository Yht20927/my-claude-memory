#!/bin/bash
# ============================================================================
# mcmMark - 标注 chunk 的来源/证据等级 (v3.3)
# ----------------------------------------------------------------------------
# 调整 chunk 的 source / evidence frontmatter 字段，从而改变其在 BM25 注入
# 中的权重（final_score = bm25 × source_w × evidence_w）。用于人工"提升"
# 已验证知识，或"降级"猜测性内容 —— 防幻觉的核心杠杆。
#
# 权重表（见 lib/inject.sh find_relevant_memories）:
#   source:   user=1.0  agent=0.7  system=0.5
#   evidence: validated=1.0  observed=0.85  hypothesis=0.6
#   缺省（init/sync 生成）= agent × observed = 0.595（折扣）
#
# Usage: mcmMark <名称> [--chunk <chunk名>] [--source user|agent|system]
#                  [--evidence validated|observed|hypothesis] [--global]
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
source "$LIB_DIR/core.sh"

NAME=""
CHUNK=""
NEW_SOURCE=""
NEW_EVIDENCE=""
IS_GLOBAL=false

VALID_SOURCES="user agent system"
VALID_EVIDENCES="validated observed hypothesis"

# ----------------------------------------------------------------------------
# 参数解析
# ----------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --chunk)        CHUNK="$2"; shift 2 ;;
            --source)       NEW_SOURCE="$2"; shift 2 ;;
            --evidence)     NEW_EVIDENCE="$2"; shift 2 ;;
            --global)       IS_GLOBAL=true; shift ;;
            --help)         usage "用法: mcmMark <名称> [--chunk <chunk名>] [--source user|agent|system] [--evidence validated|observed|hypothesis] [--global]" ;;
            *)              NAME="$1"; shift ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# 校验 source / evidence 取值
# ----------------------------------------------------------------------------

validate_values() {
    if [ -z "$NAME" ]; then
        echo "用法: mcmMark <名称> [--chunk <chunk名>] [--source ...] [--evidence ...] [--global]"
        exit 1
    fi
    if [ -z "$NEW_SOURCE" ] && [ -z "$NEW_EVIDENCE" ]; then
        echo "错误: 至少指定 --source 或 --evidence 之一"
        exit 1
    fi
    if [ -n "$NEW_SOURCE" ] && ! printf '%s\n' $VALID_SOURCES | grep -Fxq -- "$NEW_SOURCE"; then
        echo "错误: --source 必须是 user|agent|system 之一（得到: $NEW_SOURCE）"
        exit 1
    fi
    if [ -n "$NEW_EVIDENCE" ] && ! printf '%s\n' $VALID_EVIDENCES | grep -Fxq -- "$NEW_EVIDENCE"; then
        echo "错误: --evidence 必须是 validated|observed|hypothesis 之一（得到: $NEW_EVIDENCE）"
        exit 1
    fi
}

# ----------------------------------------------------------------------------
# Step 1: 定位记忆
# ----------------------------------------------------------------------------

step1_detect() {
    local memory_path
    memory_path=$(find_memory_path "$NAME" "$IS_GLOBAL")
    [ -z "$memory_path" ] && { echo ""; return; }
    echo "$memory_path"
}

# ----------------------------------------------------------------------------
# Step 2: 更新 chunk frontmatter（单次 Python 批量）
# ----------------------------------------------------------------------------

step2_mark() {
    local memory_path="$1"
    local chunks_dir="$memory_path/chunks"
    [ -d "$chunks_dir" ] || { echo "错误: 无 chunks 目录: $chunks_dir"; exit 1; }

    local -a targets=()
    if [ -n "$CHUNK" ]; then
        # 指定单个 chunk（允许带不带 .md 后缀）
        local cn="$CHUNK"
        [[ "$cn" != *.md ]] && cn="${cn}.md"
        local target="$chunks_dir/$cn"
        [ -f "$target" ] || { echo "错误: 未找到 chunk: $CHUNK"; exit 1; }
        targets+=("$target")
    else
        # 全部 chunk
        local c
        for c in "$chunks_dir"/*.md; do
            [ -f "$c" ] && targets+=("$c")
        done
    fi

    [ ${#targets[@]} -eq 0 ] && { echo "错误: 无 chunk 可标记"; exit 1; }

    # 批量更新 frontmatter：source/evidence 字段存在则替换，否则在首行 --- 后插入
    # 返回实际写入的 chunk 数（Python n，单一 stdout）
    $PYTHON -c "
import re, sys, json
paths = json.loads(sys.argv[1])
source = sys.argv[2] or None
evidence = sys.argv[3] or None
n = 0
for path in paths:
    try:
        with open(path, 'r') as f:
            c = f.read()
        # 确保 frontmatter 存在（首行 ---）
        if not c.startswith('---\n'):
            c = '---\n\n---\n' + c
        for field, val in (('source', source), ('evidence', evidence)):
            if not val:
                continue
            pat = re.compile(r'^' + field + r':.*$', re.MULTILINE)
            if pat.search(c):
                c = pat.sub(field + ': ' + val, c)
            else:
                # 在第一个 --- 之后插入
                c = re.sub(r'^---\n', '---\n' + field + ': ' + val + '\n', c, count=1)
        with open(path, 'w') as f:
            f.write(c)
        n += 1
    except Exception as e:
        sys.stderr.write('warn: %s: %s\n' % (path, e))
print(n)
" "$(printf '%s\n' "${targets[@]}" | $PYTHON -c "import json,sys; print(json.dumps([l for l in sys.stdin.read().split(chr(10)) if l]))")" "$NEW_SOURCE" "$NEW_EVIDENCE" 2>/dev/null
}

# ----------------------------------------------------------------------------
# Step 3: 重建搜索索引 + op-log
# ----------------------------------------------------------------------------

step3_reindex() {
    local memory_path="$1" marked_count="$2"
    # 重建该记忆的索引段（remove + append，写入新的 mcm-meta 行）
    update_search_index "$NAME" "$memory_path" "$IS_GLOBAL"

    local detail=""
    [ -n "$NEW_SOURCE" ] && detail="source=$NEW_SOURCE"
    [ -n "$NEW_EVIDENCE" ] && detail="${detail:+$detail }evidence=$NEW_EVIDENCE"
    detail="$detail chunks=$marked_count"
    [ -n "$CHUNK" ] && detail="$detail chunk=$CHUNK"

    log_memory_op "$memory_path" "mark" "$detail" "user"
}

# ----------------------------------------------------------------------------
# 主函数
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"
    validate_values

    log "开始标注记忆: $NAME"

    local memory_path
    memory_path=$(step1_detect)
    if [ -z "$memory_path" ]; then
        echo "错误: 未找到记忆: $NAME"
        exit 1
    fi
    log "  路径: $memory_path"

    local lock_name="mark_${NAME}"
    local lock_token=$(acquire_lock "$lock_name")
    mcm_on_exit "release_lock '$lock_name' '$lock_token'"

    local marked_count
    marked_count=$(step2_mark "$memory_path")

    step3_reindex "$memory_path" "$marked_count"

    release_lock "$lock_name" "$lock_token"
    mcm_clear_exit_handlers

    log "标注完成: $marked_count 个 chunk 已更新"
}

mcm_run_command main "$@"
