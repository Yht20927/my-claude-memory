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
DRIFT_MODE=false
WORKSPACE="${MCM_WORKSPACE:-$(pwd)}"

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) JSON_OUTPUT=true; shift ;;
            --drift) DRIFT_MODE=true; shift ;;
            --workspace) WORKSPACE="$2"; shift 2 ;;
            --help) usage "用法: mcmStatus [--json] [--drift] [--workspace PATH]" ;;
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
# Drift 报告 (v3.3 — 100 点评分制，mex 风格)
# ----------------------------------------------------------------------------
# 每个记忆独立打分，满分 100，扣分项：
#   - broken L4 链接   ×8   （仅项目记忆有 .claude/）
#   - orphan chunk     ×8   （frontmatter source_file 指向的文件已删；空 source 视为会话摘要/canary，跳过）
#   - 陈旧 chunk       ×4   （mtime > MCM_DRIFT_STALE_DAYS 天，默认 30）
#   - 索引缺失         ×4   （chunk 存在但未被 $SEARCH_INDEX 收录 → 搜索召回不到）
#   - 占位 chunk       ×2   （含 [待AI补充，尚未经 AI 浓缩）
# 等级：A(≥95) B(≥80) C(≥60) D(≥40) F(<40)
# 排除 .canary/（mcmDoctor 的探针，非用户数据）
# ----------------------------------------------------------------------------

# 分数 → 等级
_drift_grade() {
    local s="$1"
    if   [ "$s" -ge 95 ]; then echo A
    elif [ "$s" -ge 80 ]; then echo B
    elif [ "$s" -ge 60 ]; then echo C
    elif [ "$s" -ge 40 ]; then echo D
    else                      echo F
    fi
}

# 统计一个记忆中"存在于磁盘但未被搜索索引收录"的 chunk 数
# 缺失项追加到 $issues_tmp 文件（规避命令替换子壳陷阱）
_count_unindexed_chunks() {
    local name="$1" chunks_dir="$2" is_global="$3" issues_tmp="$4"
    local total
    total=$(ls "$chunks_dir"/*.md 2>/dev/null | wc -l)
    total=${total// /}
    [ "$total" -eq 0 ] && { echo 0; return; }
    [ -f "$SEARCH_INDEX" ] || { echo "$total"; return; }

    # 从索引中抽取该记忆所有已收录的 chunk 名（精确匹配记忆名 + global 标志）
    local indexed
    indexed=$(awk -v name="$name" -v want_global="$is_global" '
        /^===== / {
            line = $0
            sub(/^===== /, "", line); sub(/ =====$/, "", line)
            is_g = (line ~ /^\[global\] /)
            if (is_g) sub(/^\[global\] /, "", line)
            n = line; sub(/ \/ .*/, "", n)
            c = line; sub(/^[^\/]*\/ /, "", c)
            if (n == name && ((want_global == "true" && is_g) || (want_global != "true" && !is_g)))
                print c
        }
    ' "$SEARCH_INDEX" 2>/dev/null)

    local missing=0 chunk cn
    for chunk in "$chunks_dir"/*.md; do
        [ -f "$chunk" ] || continue
        cn=$(basename "$chunk")
        if ! printf '%s\n' "$indexed" | grep -Fxq -- "$cn"; then
            missing=$((missing + 1))
            printf 'index-mismatch: %s (chunk 未被搜索索引收录)\n' "${chunk#$MEMORY_BASE/}" >> "$issues_tmp"
        fi
    done
    echo "$missing"
}

# 扫描单个记忆，输出行 "name|tag|score|grade|broken|stale|orphan|placeholder|mismatch"
# 详情（issues）追加到 $issues_tmp 文件（命令替换会开子壳，数组/计数器副作用
# 无法逃逸 —— 改走文件传递，规避 v2.3 同类 subshell 陷阱）
_drift_scan_memory() {
    local dir="$1" tag="$2" is_global="$3" stale_days="$4" issues_tmp="$5"
    local name=$(basename "$dir")
    local broken=0 stale=0 orphan=0 placeholder=0 mismatch=0

    # L4 健康（仅项目记忆）
    if [ "$is_global" = false ] && [ -d "$dir/.claude" ]; then
        local res b
        res=$(check_l4_health "$dir/.claude" 2>/dev/null)
        b=$(echo "$res" | cut -d' ' -f2)
        b=${b:-0}
        if [ "$b" -gt 0 ]; then
            broken=$b
            printf 'broken-l4: %s.claude (%d 个失效链接)\n' "${dir#$MEMORY_BASE/}" "$b" >> "$issues_tmp"
        fi
    fi

    # chunk 级扫描
    local chunk src
    for chunk in "$dir/chunks"/*.md; do
        [ -f "$chunk" ] || continue
        # orphan: source_file 非空且指向的文件不存在
        src=$(grep '^source_file: ' "$chunk" 2>/dev/null | head -1 | sed 's/^source_file: //')
        if [ -n "$src" ] && [ "$src" != '""' ] && [ ! -f "$src" ]; then
            orphan=$((orphan + 1))
            printf 'orphan: %s → %s (源文件已删)\n' "${chunk#$MEMORY_BASE/}" "$src" >> "$issues_tmp"
        fi
        # stale: mtime 超过阈值
        if [ -n "$(find "$chunk" -mtime +"$stale_days" 2>/dev/null)" ]; then
            stale=$((stale + 1))
            printf 'stale: %s (mtime 超过 %dd)\n' "${chunk#$MEMORY_BASE/}" "$stale_days" >> "$issues_tmp"
        fi
        # placeholder: 未经 AI 浓缩
        if grep -qF '[待AI补充' "$chunk" 2>/dev/null; then
            placeholder=$((placeholder + 1))
        fi
    done

    # 索引缺失
    mismatch=$(_count_unindexed_chunks "$name" "$dir/chunks" "$is_global" "$issues_tmp")

    local penalty=$((broken*8 + orphan*8 + stale*4 + mismatch*4 + placeholder*2))
    local score=$((100 - penalty))
    [ "$score" -lt 0 ] && score=0
    local grade=$(_drift_grade "$score")

    echo "$name|$tag|$score|$grade|$broken|$stale|$orphan|$placeholder|$mismatch"
}

drift_report() {
    local stale_days="${MCM_DRIFT_STALE_DAYS:-30}"
    local -a rows=()
    local -a issues=()
    local issues_tmp
    issues_tmp=$(mktemp -t mcm-drift-XXXXXX)

    # 项目记忆
    local tag dir
    for tag in $(get_project_tags 2>/dev/null); do
        [ ! -d "$PROJECTS_DIR/$tag" ] && continue
        for dir in "$PROJECTS_DIR/$tag"/*/; do
            [ -d "$dir" ] || continue
            dir="${dir%/}"
            [[ "$dir" == */.canary/* ]] && continue
            rows+=("$(_drift_scan_memory "$dir" "$tag" false "$stale_days" "$issues_tmp")")
        done
    done

    # 全局记忆（无 L4）
    local mode
    for mode in $(get_global_modes 2>/dev/null); do
        [ ! -d "$GLOBAL_DIR/$mode" ] && continue
        for dir in "$GLOBAL_DIR/$mode"/*/; do
            [ -d "$dir" ] || continue
            dir="${dir%/}"
            [[ "$dir" == */.canary/* ]] && continue
            rows+=("$(_drift_scan_memory "$dir" "$mode" true "$stale_days" "$issues_tmp")")
        done
    done

    # 收集 issues（helper 写到临时文件，规避子壳陷阱）
    if [ -s "$issues_tmp" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && issues+=("$line")
        done < "$issues_tmp"
    fi
    rm -f "$issues_tmp"

    # 从 rows 派生计数器（避免 helper 子壳副作用）
    local mem_count=${#rows[@]}
    local total_score=0 row
    for row in "${rows[@]}"; do
        local sc
        sc=$(printf '%s' "$row" | cut -d'|' -f3)
        total_score=$((total_score + ${sc:-0}))
    done

    local fleet_avg=0
    if [ "$mem_count" -gt 0 ]; then
        fleet_avg=$(awk -v t="$total_score" -v n="$mem_count" 'BEGIN{printf "%.1f", t/n}')
    fi
    local fleet_grade
    if [ "$mem_count" -gt 0 ]; then
        fleet_grade=$(_drift_grade "${fleet_avg%.*}")
    else
        fleet_grade="-"
    fi
    local total_issues=${#issues[@]}

    # ---------- JSON 输出 ----------
    if [ "$JSON_OUTPUT" = true ]; then
        $PYTHON -c "
import json, sys
rows = sys.argv[1].split('\\n') if sys.argv[1] else []
issues = sys.argv[2].split('\\n') if sys.argv[2] else []
memories = []
for r in rows:
    if not r: continue
    p = r.split('|')
    if len(p) < 9: continue
    memories.append({
        'name': p[0], 'tag': p[1], 'score': int(p[2]), 'grade': p[3],
        'broken_l4': int(p[4]), 'stale': int(p[5]), 'orphan': int(p[6]),
        'placeholder': int(p[7]), 'index_mismatch': int(p[8]),
    })
data = {
    'drift': {
        'stale_days': int(sys.argv[3]),
        'fleet_avg': float(sys.argv[4]),
        'fleet_grade': sys.argv[5],
        'memory_count': int(sys.argv[6]),
        'total_issues': int(sys.argv[7]),
        'memories': memories,
        'issues': [i for i in issues if i],
    }
}
print(json.dumps(data, indent=2, ensure_ascii=False))
" "$(IFS=$'\n'; echo "${rows[*]}")" \
  "$(IFS=$'\n'; echo "${issues[*]}")" \
  "$stale_days" "$fleet_avg" "$fleet_grade" "$mem_count" "$total_issues"
        return
    fi

    # ---------- 文本输出 ----------
    echo ""
    echo "## Drift 报告 (v3.3 — 评分制)"
    echo ""
    echo "阈值: stale > ${stale_days}d  |  扣分: L4×8 orphan×8 stale×4 mismatch×4 placeholder×2"
    echo ""

    if [ "$mem_count" -eq 0 ]; then
        echo "无记忆，跳过 drift 评分。"
        return
    fi

    echo "| 记忆 | 标签 | 分数 | 等级 | L4 | stale | orphan | 占位 | 索引缺失 |"
    echo "|------|------|------|------|----|----|--------|------|----------|"
    local row
    for row in "${rows[@]}"; do
        IFS='|' read -r n t sc gr br st or ph mm <<< "$row"
        echo "| $n | $t | $sc | $gr | $br | $st | $or | $ph | $mm |"
    done
    echo ""
    echo "**舰队均值**: ${fleet_avg}/100 (${fleet_grade})  ·  共 ${mem_count} 个记忆"
    echo ""

    if [ "$total_issues" -eq 0 ]; then
        echo "✓ 无 drift 信号"
    else
        echo "详情 (${total_issues} 项):"
        local issue
        for issue in "${issues[@]}"; do
            echo "  - $issue"
        done
        echo ""
        echo "提示: mcmDoctor --fix 可清理部分问题；mcmMark --evidence validated 可提升 chunk 权重"
    fi
}

# ----------------------------------------------------------------------------
# 主函数
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"

    # v3.2: --drift 模式只出 drift 报告
    if [ "$DRIFT_MODE" = true ]; then
        drift_report
        return
    fi

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

mcm_run_command main "$@"
