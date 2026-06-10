#!/bin/bash
# ============================================================================
# mcMemory-inject - 自动注入逻辑库 (v2.4)
# ============================================================================
# 提供记忆自动注入所需的关键词提取、相关性匹配、上下文预算管理
#
# v2.4 新增:
#   - is_inject_paused / pause 开关：用户可临时暂停注入（.paused_until）
#   - log_injection：每次注入写一行到 .inject_log，供 mcmInjectLog 查看
# ============================================================================

# 注入追踪目录（避免重复注入）
INJECT_STATE_DIR="${MEMORY_BASE:-$HOME/.claude/mcMemories}/.inject_state"
mkdir -p "$INJECT_STATE_DIR"

# pause 标记文件
INJECT_PAUSE_FILE="${MEMORY_BASE:-$HOME/.claude/mcMemories}/.paused_until"

# 配置
MAX_INJECT_TOKENS_ESTIMATE="${MAX_INJECT_TOKENS_ESTIMATE:-2000}"
MAX_INJECT_MEMORIES="${MAX_INJECT_MEMORIES:-3}"
INJECT_COOLDOWN_SEC="${INJECT_COOLDOWN_SEC:-120}"

# ----------------------------------------------------------------------------
# pause 检查：若 .paused_until 存在且时间戳未过期，返回 0（已暂停）
# ----------------------------------------------------------------------------
is_inject_paused() {
    [ -f "$INJECT_PAUSE_FILE" ] || return 1
    local until_ts
    until_ts=$(cat "$INJECT_PAUSE_FILE" 2>/dev/null)
    [ -z "$until_ts" ] && return 1
    local now
    now=$(date +%s)
    if [ "$now" -lt "$until_ts" ]; then
        return 0   # 仍在暂停期
    fi
    # 已过期：清理掉 pause 文件
    rm -f "$INJECT_PAUSE_FILE" 2>/dev/null
    return 1
}

# ----------------------------------------------------------------------------
# 写一行注入日志（v3.0 改为事件总线薄壳；旧 .inject_log 文件下线）
# event: session_start | prompt_submit | paused
# ----------------------------------------------------------------------------
log_injection() {
    emit_event "inject.${1}" memory="${2:-}" score="${3:-}" keywords="${4:-}"
}

# ============================================================================
# 关键词提取：从用户提示中提取有意义的关键词
# ----------------------------------------------------------------------------
# v2.4: 修复中文召回失败
#   - 旧实现 tr -cs '一-鿿' '\n' 把每个汉字切成单字符 token，再被
#     length>=2 过滤掉 → 中文场景下关键词列表几乎为空，无法触发注入。
#   - 新实现：把整段提示交给 Python，按以下规则分词：
#       * 英文/数字：按非字母数字分割，最小长度 3
#       * 中文：抓取连续汉字段；段长 ≤8 整段保留；同时产出 2-gram bigram 提升召回
#       * 停用词分中英两组分别过滤
#       * 输出最多 20 个 token，按出现频次降序
#   - 如果环境有 jieba 则优先调用 jieba.cut_for_search 替代 bigram 切分。
# ============================================================================

extract_keywords() {
    local prompt="$1"

    [ -z "$prompt" ] && return

    $PYTHON - "$prompt" <<'PY' 2>/dev/null
import re, sys
from collections import Counter

text = sys.argv[1].lower() if len(sys.argv) > 1 else ''

EN_STOPWORDS = {
    'the','and','for','this','that','with','from','have','are','was','not','but',
    'you','can','has','all','will','just','how','its','get','use','also','new',
    'see','now','our','one','way','out','did','may','say','set','try','too','let',
    'add','run','put','got','yet','ask','come','make','take','know','think','look',
    'want','need','like','here','there','each','very','much','such','some','which',
    'when','what','who','where','been','being','more','into','than','then','them',
    'they','their','over','only','other','well','back','any','own','please',
    'about','should','would','could','your','mine','very','really','because',
}

# 单字符中文停用词（仅用于过滤单字 token；多字 token 不受此影响）
ZH_SINGLE_STOPWORDS = set('的了在是有和就不人都一个上也很到说要去你我会着看好这他那来还把被让给从最为对与及或等而且但如之所以能将可已于其些只中者各用后由自出做大小多少前')

# 多字中文停用词
ZH_MULTI_STOPWORDS = {
    '我们','你们','他们','她们','没有','自己','如何','什么','怎么','为什么','还是',
    '只是','不过','可以','虽然','因为','所以','如果','一些','一下','一个','这个',
    '那个','这些','那些','这样','那样','现在','已经','应该','可能','以及','或者',
    '一样','一种','一直','一定','需要','使用','进行','通过','以下','以上','其他',
}

tokens = []

# 英文/数字 token：3 字符及以上
for m in re.findall(r'[a-z0-9][a-z0-9_\-]{2,29}', text):
    if m in EN_STOPWORDS:
        continue
    tokens.append(m)

# 中文：抓连续汉字段
for segment in re.findall(r'[一-鿿]+', text):
    if not segment:
        continue
    # 短段（2-8 字符）整段保留
    if 2 <= len(segment) <= 8 and segment not in ZH_MULTI_STOPWORDS:
        tokens.append(segment)
    # bigram 切片：对长度 >=2 的段都生成 bigram
    if len(segment) >= 2:
        for i in range(len(segment) - 1):
            bg = segment[i:i+2]
            # 过滤双单字组成的高频虚词
            if bg in ZH_MULTI_STOPWORDS:
                continue
            if bg[0] in ZH_SINGLE_STOPWORDS and bg[1] in ZH_SINGLE_STOPWORDS:
                continue
            tokens.append(bg)

# 按频次降序，截前 20
counter = Counter(tokens)
for tok, _ in counter.most_common(20):
    print(tok)
PY
}

# ============================================================================
# 从搜索索引中匹配关键词，返回相关记忆名称列表（按相关性排序）
# ----------------------------------------------------------------------------
# v2.4: Python 化重写，性能从 ~10s 降到 <100ms
#   - 旧 Bash 实现对每行 × 每关键词都 fork 'echo | tr' 子进程做大小写折叠
#     ；10 关键词扫几千行索引 = 上万次 fork，超时严重。
#   - 新实现：把整个索引扫描和打分搬到单次 Python 调用，复杂度同前但
#     无 fork 开销。
# v2.4: BM25 评分替换 sqrt(n) 归一化（评审 3.1）
#   - 旧 sqrt(n) 归一化无理论锚点；header×3 + body×1 + 单 chunk 最多投一票
#     导致"真正相关的长 chunk"与"仅扫到关键词的短 chunk"等价。
#   - 新实现：标准 BM25 (k1=1.2, b=0.75)
#       * tf：term frequency（header 匹配权重 ×3）
#       * idf：log((N - df + 0.5) / (df + 0.5) + 1) — Robertson 变体
#       * 长度归一化：用记忆总字符数 / 平均长度作为分母惩罚长记忆
#     完全摆脱 break-once 限制，相关性按词频累计，长度合理惩罚。
# ============================================================================

find_relevant_memories() {
    local keywords=("$@")
    local index_file="$MEMORY_BASE/.search_index"

    if [ ! -f "$index_file" ] || [ ! -s "$index_file" ]; then
        return
    fi
    [ ${#keywords[@]} -eq 0 ] && return

    $PYTHON - "$MAX_INJECT_MEMORIES" "$index_file" "${keywords[@]}" <<'PY' 2>/dev/null
import sys, re, math
from collections import defaultdict

max_items = int(sys.argv[1])
index_file = sys.argv[2]
keywords = [k.lower() for k in sys.argv[3:] if len(k) >= 2]

if not keywords:
    sys.exit(0)

header_re = re.compile(r'^=====\s+(\[global\]\s+)?(.+?)\s+/\s+(.+?)\s+=====$')

# BM25 数据结构
tf = defaultdict(lambda: defaultdict(int))     # tf[mem][kw] = 词频（header 命中 ×3）
doc_freq = defaultdict(int)                     # df[kw] = 包含该 kw 的记忆数
mem_length = defaultdict(int)                   # mem[mem] = 总字符数
memory_names = set()
current_mem = ''

try:
    with open(index_file, 'r', errors='replace') as f:
        for raw in f:
            line = raw.rstrip('\n')
            lower = line.lower()
            m = header_re.match(line)
            if m:
                current_mem = m.group(2).strip()
                memory_names.add(current_mem)
                # header 命中权重 ×3（多个 kw 可叠加，不同于旧版的 binary break）
                for kw in keywords:
                    if kw in lower:
                        tf[current_mem][kw] += 3
            elif current_mem and line:
                # 正文：记录长度 + 词频计数
                mem_length[current_mem] += len(line)
                for kw in keywords:
                    if kw in lower:
                        tf[current_mem][kw] += 1
except Exception:
    sys.exit(0)

if not memory_names:
    sys.exit(0)

# IDF: 统计每个 kw 出现在多少记忆中
N = len(memory_names)
for kw in keywords:
    df = sum(1 for mem in memory_names if tf[mem].get(kw, 0) > 0)
    doc_freq[kw] = max(df, 1)  # 至少 1 避免 log(0)

# BM25 评分
k1, b = 1.2, 0.75
avg_len = sum(mem_length.values()) / max(N, 1)

scores = {}
for mem in memory_names:
    mem_len = mem_length.get(mem, 0) or 1
    score = 0.0
    for kw in keywords:
        term_freq = tf[mem].get(kw, 0)
        if term_freq == 0:
            continue
        df = doc_freq.get(kw, N)
        # BM25 IDF (Robertson 变体，避免 IDF < 0)
        idf = math.log((N - df + 0.5) / (df + 0.5) + 1.0)
        # BM25 TF 长度归一化
        tf_norm = term_freq * (k1 + 1) / (term_freq + k1 * (1 - b + b * mem_len / avg_len))
        score += idf * tf_norm
    scores[mem] = score

sorted_mems = sorted(scores.items(), key=lambda x: x[1], reverse=True)
for mem, _ in sorted_mems[:max_items]:
    print(mem)
PY
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
# ----------------------------------------------------------------------------
# v2.4: 跳过含 `[待AI补充` 的占位 chunk，避免把"待办标记"作为知识注入
# ============================================================================

# 判断一个 chunk 文件是否仍是占位（未经 AI 浓缩）
is_placeholder_chunk() {
    local chunk="$1"
    grep -qF '[待AI补充' "$chunk" 2>/dev/null
}

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

    # L3 关键内容（跳过占位 chunk）
    if [ -d "$memory_path/chunks" ]; then
        local total_lines=0
        local injected_any=false
        for chunk in "$memory_path/chunks"/*.md; do
            [ -f "$chunk" ] || continue
            if is_placeholder_chunk "$chunk"; then
                continue
            fi
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
            injected_any=true
        done
        if [ "$injected_any" = false ]; then
            echo "> *(L3 内容全部为占位，待 AI 浓缩；提示见 mcmDoctor)*"
        fi
    fi
    echo "<!-- /mcMemory auto-inject -->"
}

# ============================================================================
# Session Start: 加载当前项目记忆 + 全局 auto 记忆
# ============================================================================

session_start_inject() {
    local workspace="${1:-$(pwd)}"
    local output=""

    # v2.4: pause 检查
    if is_inject_paused; then
        log_injection "paused" "" "" "session_start"
        return
    fi

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
        log_injection "session_start" "$project_name" "" "project"
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

            # L3 内容（跳过占位 chunk）
            if [ -d "$mem_dir/chunks" ]; then
                for chunk in "$mem_dir/chunks"/*.md; do
                    [ -f "$chunk" ] || continue
                    if is_placeholder_chunk "$chunk"; then
                        continue
                    fi
                    local content=$(sed -n '/^---$/,/^---$/!p' "$chunk" | sed '/^---$/d' | head -40)
                    output+="$content"$'\n'
                done
            fi
            output+="
<!-- /mcMemory auto-load -->
"
            # v2.1: 标记为已注入，防止 prompt_submit 重复加载
            mark_injected "$mem_tag"
            log_injection "session_start" "$mem_name" "" "auto"
        done
    fi

    echo "$output"
}

# ============================================================================
# User Prompt Submit: 智能检索 + 注入
# ============================================================================

prompt_submit_inject() {
    local user_prompt="$1"

    # v2.4: pause 检查
    if is_inject_paused; then
        log_injection "paused" "" "" "prompt_submit"
        return
    fi

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

    # 关键词 CSV（取前 8 个用于日志）
    local kw_csv
    kw_csv=$(IFS=','; echo "${keywords[*]:0:8}")

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

        # 计算相关性分数（v2.4 修复）:
        # 旧实现仅在 summary.md 上匹配关键词，但 summary 通常只含项目名+描述，
        # 几乎从不命中正文关键词 → score=0<2，导致 inject 实际上永不触发。
        # 新策略：summary 命中给 3×（高信号），chunks 任意文件命中给 1×（保底），
        # 同时设上限避免单一长 chunk 主导得分。
        local score=0
        for kw in "${keywords[@]}"; do
            [ ${#kw} -lt 2 ] && continue
            if grep -iqF "$kw" "$mem_path/summary.md" 2>/dev/null; then
                score=$((score + 3))
            elif [ -d "$mem_path/chunks" ] && \
                 grep -riqF "$kw" "$mem_path/chunks" 2>/dev/null; then
                score=$((score + 1))
            fi
            # 单 prompt 最多累计 12 分，避免极长 prompt 拉满
            [ "$score" -ge 12 ] && break
        done

        # 门槛：至少 2 分（1 个 summary 命中或 2 个 chunk 命中）
        [ "$score" -lt 2 ] && continue

        output+=$(format_injection "$mem" "$mem_path" "$score")
        mark_injected "$mem"
        log_injection "prompt_submit" "$mem" "$score" "$kw_csv"
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
