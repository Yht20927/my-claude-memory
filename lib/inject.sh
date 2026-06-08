#!/bin/bash
# ============================================================================
# mcMemory-inject - 自动注入逻辑库 (v2.1)
# ============================================================================
# 提供记忆自动注入所需的关键词提取、相关性匹配、上下文预算管理
# ============================================================================

# 注入追踪目录（避免重复注入）
INJECT_STATE_DIR="${MEMORY_BASE:-$HOME/.claude/mcMemories}/.inject_state"
mkdir -p "$INJECT_STATE_DIR"

# 配置
MAX_INJECT_TOKENS_ESTIMATE="${MAX_INJECT_TOKENS_ESTIMATE:-2000}"
MAX_INJECT_MEMORIES="${MAX_INJECT_MEMORIES:-3}"
INJECT_COOLDOWN_SEC="${INJECT_COOLDOWN_SEC:-120}"

# ============================================================================
# 关键词提取：从用户提示中提取有意义的关键词
# ============================================================================

extract_keywords() {
    local prompt="$1"

    echo "$prompt" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9一-鿿' '\n' | \
        grep -vE '^(the|and|for|this|that|with|from|have|are|was|not|but|you|can|has|all|will|just|how|its|get|use|also|new|see|now|our|one|way|out|did|may|say|set|try|too|let|add|run|put|got|yet|ask|come|make|take|know|think|look|want|need|like|here|there|each|very|much|such|some|which|when|what|who|how|where|been|being|been|more|into|than|then|them|they|their|over|only|other|well|back|any|own|see|us|她|我们|是|的|了|在|有|和|就|不|人|都|一|个|上|也|很|到|说|要|去|你|会|着|没有|看|好|自己|这|他|那|来|还|把|被|让|给|从|最|为|对|与|及|或|等|而|且|但|如|之|所|以|能|将|可|已|于|其|些|只|中|及|者|我|各|用|后|由|自|出|做|大|小|多|少|前|虽然|因为|所以|如果|可以|什么|怎么|为什么|还是|只是|不过)$' | \
        grep -E '^.{2,30}$' | sort -u | head -20
}

# ============================================================================
# 从搜索索引中匹配关键词，返回相关记忆名称列表（按相关性排序）
# v2.1: 扫描索引全部内容（不仅是header），用固定字符串匹配
# ============================================================================

find_relevant_memories() {
    local keywords=("$@")
    local index_file="$MEMORY_BASE/.search_index"

    if [ ! -f "$index_file" ] || [ ! -s "$index_file" ]; then
        return
    fi

    declare -A header_scores  # header（chunk 名称）匹配得分（3×权重）
    declare -A body_scores    # 正文匹配得分
    declare -A chunk_counts   # 每个记忆的 chunk 数量
    declare -A seen_chunks    # 当前记忆的 chunk 去重
    local current_mem=""
    local current_chunk=""

    # 单次扫描索引：逐行追踪当前所属记忆和 chunk
    while IFS= read -r line; do
        # 检测 header 行: "===== [global] memory_name / chunk_name ====="
        if [[ "$line" =~ ^=====\ (\[global\]\ )?([^/]+)\ /\ (.+)\ ===== ]]; then
            current_mem="${BASH_REMATCH[2]}"
            current_mem=$(echo "$current_mem" | xargs)  # trim
            current_chunk="${BASH_REMATCH[3]}"
            current_chunk=$(echo "$current_chunk" | xargs)

            # 统计 chunk 数量（去重）
            local ck="${current_mem}::${current_chunk}"
            if [ -z "${seen_chunks[$ck]}" ]; then
                seen_chunks[$ck]=1
                chunk_counts["$current_mem"]=$((${chunk_counts["$current_mem"]:-0} + 1))
            fi

            # 在 header 行中匹配关键词（命中 → 3× 权重）
            # 匹配完整 header line（包含 memory_name 和 chunk_name）
            local lower_header=$(echo "$line" | tr '[:upper:]' '[:lower:]')
            for kw in "${keywords[@]}"; do
                [ ${#kw} -lt 2 ] && continue
                local lower_kw=$(echo "$kw" | tr '[:upper:]' '[:lower:]')
                if [[ "$lower_header" == *"$lower_kw"* ]]; then
                    header_scores["$current_mem"]=$((${header_scores["$current_mem"]:-0} + 3))
                    break
                fi
            done
        elif [ -n "$current_mem" ] && [ -n "$line" ]; then
            # 正文行匹配（1× 权重）
            local lower_line=$(echo "$line" | tr '[:upper:]' '[:lower:]')
            for kw in "${keywords[@]}"; do
                [ ${#kw} -lt 2 ] && continue
                local lower_kw=$(echo "$kw" | tr '[:upper:]' '[:lower:]')
                if [[ "$lower_line" == *"$lower_kw"* ]]; then
                    body_scores["$current_mem"]=$((${body_scores["$current_mem"]:-0} + 1))
                    break
                fi
            done
        fi
    done < "$index_file"

    # 合并得分：header(3×) + body(1×)，按 chunk_count 平方根归一化
    # 通过单个 Python 调用排序（避免依赖系统 sort，Windows sort.exe 不兼容）
    {
        for mem in "${!header_scores[@]}" "${!body_scores[@]}"; do
            local h=${header_scores["$mem"]:-0}
            local b=${body_scores["$mem"]:-0}
            local n=${chunk_counts["$mem"]:-1}
            local raw=$((h + b))
            echo "$raw $n $mem"
        done
    } | $PYTHON -c "
import math, sys
max_items = int(sys.argv[1])
entries = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    parts = line.split(None, 2)
    if len(parts) < 3:
        continue
    raw = int(parts[0])
    n = int(parts[1])
    name = parts[2]
    norm = int(raw / math.sqrt(n)) if n > 0 else raw
    entries.append((norm, name))
entries.sort(key=lambda x: x[0], reverse=True)
for _, name in entries[:max_items]:
    print(name)
" "$MAX_INJECT_MEMORIES" 2>/dev/null
}

# ============================================================================
# 检查记忆是否在冷却期内
# ============================================================================

is_in_cooldown() {
    local memory_name="$1"
    local state_file="$INJECT_STATE_DIR/${memory_name}.last"

    if [ -f "$state_file" ]; then
        local last_time=$(cat "$state_file")
        local now=$(date +%s)
        if [ $((now - last_time)) -lt "$INJECT_COOLDOWN_SEC" ]; then
            return 0
        fi
    fi
    return 1
}

# 标记记忆已被注入
mark_injected() {
    local memory_name="$1"
    date +%s > "$INJECT_STATE_DIR/${memory_name}.last"
}

# ============================================================================
# 格式化记忆内容为注入文本
# ============================================================================

format_injection() {
    local memory_name="$1"
    local memory_path="$2"
    local relevance="$3"

    echo ""
    echo "<!-- mcMemory auto-inject: $memory_name (relevance: $relevance) -->"
    echo "> **相关记忆**: \`$memory_name\`"

    # L1 概览
    if [ -f "$memory_path/summary.md" ]; then
        head -2 "$memory_path/summary.md" | while read -r line; do
            echo "> $line"
        done
    fi

    # L3 关键内容
    if [ -d "$memory_path/chunks" ]; then
        local total_lines=0
        for chunk in "$memory_path/chunks"/*.md; do
            [ -f "$chunk" ] || continue
            local content=$(sed -n '/^---$/,/^---$/!p' "$chunk" | sed '/^---$/d' | head -30)
            local chunk_lines=$(echo "$content" | wc -l)
            total_lines=$((total_lines + chunk_lines))
            if [ $total_lines -gt 50 ]; then
                echo "> ... (内容过长已截断)"
                break
            fi
            echo "$content" | while read -r line; do
                [ -n "$line" ] && echo "> $line"
            done
        done
    fi
    echo "<!-- /mcMemory auto-inject -->"
}

# ============================================================================
# Session Start: 加载当前项目记忆 + 全局 auto 记忆
# ============================================================================

session_start_inject() {
    local workspace="${1:-$(pwd)}"
    local output=""

    # 项目记忆 L1
    local project_dir=$(find_project_memory_dir "$workspace" 2>/dev/null)
    if [ -n "$project_dir" ] && [ -f "$project_dir/summary.md" ]; then
        local project_name=$(basename "$project_dir")
        local summary_text=$(head -2 "$project_dir/summary.md" | sed 's/^/> /')
        output+="
<!-- mcMemory session-start: project memory -->
> **项目记忆已加载**: \`$project_name\`
$summary_text
<!-- /mcMemory session-start -->

"
        mark_injected "${project_name}_session"
    fi

    # 全局 auto 记忆 L3（仅 auto 模式，这是设计意图）
    if [ -d "$GLOBAL_DIR/auto" ]; then
        for mem_dir in "$GLOBAL_DIR/auto"/*/; do
            [ -d "$mem_dir" ] || continue
            local mem_name=$(basename "$mem_dir")
            local mem_tag="auto_${mem_name}"
            local summary_text=$(head -2 "$mem_dir/summary.md" 2>/dev/null | sed 's/^/> /')
            output+="
<!-- mcMemory auto-load: $mem_name -->
> **自动加载记忆**: \`$mem_name\`
$summary_text

"

            # L3 内容
            if [ -d "$mem_dir/chunks" ]; then
                for chunk in "$mem_dir/chunks"/*.md; do
                    [ -f "$chunk" ] || continue
                    local content=$(sed -n '/^---$/,/^---$/!p' "$chunk" | sed '/^---$/d' | head -40)
                    output+="$content"$'\n'
                done
            fi
            output+="
<!-- /mcMemory auto-load -->
"
            # v2.1: 标记为已注入，防止 prompt_submit 重复加载
            mark_injected "$mem_tag"
        done
    fi

    echo "$output"
}

# ============================================================================
# User Prompt Submit: 智能检索 + 注入
# ============================================================================

prompt_submit_inject() {
    local user_prompt="$1"

    # 提取关键词
    local keywords=()
    while IFS= read -r kw; do
        [ -n "$kw" ] && keywords+=("$kw")
    done < <(extract_keywords "$user_prompt")

    [ ${#keywords[@]} -eq 0 ] && return

    # 查找相关记忆
    local relevant=()
    while IFS= read -r mem; do
        [ -n "$mem" ] && relevant+=("$mem")
    done < <(find_relevant_memories "${keywords[@]}")

    [ ${#relevant[@]} -eq 0 ] && return

    # 格式化注入
    local output=""
    local injected=0
    for mem in "${relevant[@]}"; do
        if is_in_cooldown "$mem"; then
            continue
        fi

        # 查找记忆路径
        local mem_path=$(find_memory_path "$mem" false 2>/dev/null)
        [ -z "$mem_path" ] && mem_path=$(find_memory_path "$mem" true 2>/dev/null)
        [ -z "$mem_path" ] && continue

        # 计算匹配关键词数作为相关性分数
        local score=0
        for kw in "${keywords[@]}"; do
            if grep -iqF "$kw" "$mem_path/summary.md" 2>/dev/null; then
                score=$((score + 3))
            fi
        done
        [ "$score" -lt 2 ] && continue

        output+=$(format_injection "$mem" "$mem_path" "$score")
        mark_injected "$mem"
        injected=$((injected + 1))
    done

    [ "$injected" -gt 0 ] && echo "$output"
}

# ============================================================================
# PreCompact: 保存会话摘要到记忆
# ============================================================================
#
# 流程:
#   1. AI 在会话中主动写 .claude/session_notes.md (SKILL.md 有指令)
#   2. PreCompact hook 调用本函数，读取 session_notes.md
#   3. 生成带时间戳的 L3 chunk 存入项目记忆 chunks/ 目录
#   4. 追加对应 section 到搜索索引
#   5. 清空 session_notes.md 以备下次会话
#   6. 若无 session_notes.md，fallback 到 .session_log.md 的简单追加

precompact_save() {
    local workspace="${1:-$(pwd)}"

    local project_dir=$(find_project_memory_dir "$workspace" 2>/dev/null)
    if [ -z "$project_dir" ]; then
        log "PreCompact: 未找到项目记忆，跳过"
        return
    fi

    local notes_file="$workspace/.claude/session_notes.md"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local date_label=$(date '+%Y-%m-%d %H:%M:%S')

    # 主路径：AI 写入了 session_notes.md
    if [ -f "$notes_file" ] && [ -s "$notes_file" ]; then
        local note_size=$(wc -l < "$notes_file" 2>/dev/null || echo 0)
        log "PreCompact: 发现 session_notes.md ($note_size 行)，生成 L3 chunk..."

        local chunks_dir="$project_dir/chunks"
        local chunk_name="session_${timestamp}.md"
        local chunk_path="$chunks_dir/$chunk_name"

        # 生成 L3 chunk（含 frontmatter + 内容）
        {
            echo "---"
            echo "source_file: $notes_file"
            echo "created: $date_label"
            echo "type: session_summary"
            echo "---"
            echo ""
            echo "# 会话摘要 — $date_label"
            echo ""
            cat "$notes_file"
        } > "$chunk_path"

        # 增量更新搜索索引
        local mem_name=$(basename "$project_dir")
        update_search_index "$mem_name" "$project_dir" false

        # 追加到 .session_log.md 元记录
        local session_log="$project_dir/.session_log.md"
        {
            echo ""
            echo "## 会话 $date_label"
            echo ""
            echo "chunk: $chunk_name ($note_size 行)"
            echo ""
        } >> "$session_log"

        # 清空 session_notes.md 以准备下次会话
        > "$notes_file"

        log "PreCompact: 会话摘要已保存 → $chunk_name"
        return
    fi

    # Fallback: 没有 session_notes.md，走旧逻辑（简单时间戳记录）
    local session_log="$project_dir/.session_log.md"
    if [ ! -f "$session_log" ]; then
        echo "# 会话日志" > "$session_log"
        echo "" >> "$session_log"
    fi

    {
        echo ""
        echo "## 会话 $date_label"
        echo ""
        echo "*(AI 未写入 session_notes.md，仅记录时间戳)*"
        echo ""
    } >> "$session_log"

    log "PreCompact: 未发现 session_notes.md，仅记录时间戳"
}
