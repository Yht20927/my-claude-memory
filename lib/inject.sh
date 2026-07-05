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

# ----------------------------------------------------------------------------
# v3.5: MEMORY_BASE 派生路径改为惰性求值（调用时读取 $MEMORY_BASE）。
#   旧实现在 source 时冻结 INJECT_STATE_DIR / INJECT_PAUSE_FILE / INJECT_STOP_FILE
#   常量，若调用方在 source 后改 MEMORY_BASE（如集成测试 it_setup 换 fixture，
#   或多 base 部署），常量仍指向旧值 → cooldown/pause/stop 写错地方，引发
#   静默失败与跨运行 flake（v3.4 phase4 journal 测试即踩此坑）。
#   现各函数内联 "${MEMORY_BASE:-$HOME/.claude/mcMemories}/<file>" 读取现行值；
#   mkdir 副作用移到 mark_injected（写时建），不在 source 时触发。
# ----------------------------------------------------------------------------

# 配置
MAX_INJECT_TOKENS_ESTIMATE="${MAX_INJECT_TOKENS_ESTIMATE:-2000}"
MAX_INJECT_MEMORIES="${MAX_INJECT_MEMORIES:-3}"
INJECT_COOLDOWN_SEC="${INJECT_COOLDOWN_SEC:-120}"
# B5 (v3.1): BM25 注入门槛。find_relevant_memories 只返回 score>0 的记忆，
# 此处设门槛过滤极弱匹配。0 = 接受任何正分（依赖 top-N + cooldown 节流）。
INJECT_BM25_MIN_SCORE="${INJECT_BM25_MIN_SCORE:-0}"

# v3.6: 加载 ledger 库（若存在），供 session_start_inject 注入未竟事项
LEDGER_LIB="$(dirname "${BASH_SOURCE[0]}")/ledger.sh"
[ -f "$LEDGER_LIB" ] && source "$LEDGER_LIB"

# ----------------------------------------------------------------------------
# pause 检查：若 .paused_until 存在且时间戳未过期，返回 0（已暂停）
# v3.5: 路径惰性求值（调用时读 $MEMORY_BASE）
# ----------------------------------------------------------------------------
is_inject_paused() {
    local pause_file="${MEMORY_BASE:-$HOME/.claude/mcMemories}/.paused_until"
    [ -f "$pause_file" ] || return 1
    local until_ts
    until_ts=$(cat "$pause_file" 2>/dev/null)
    [ -z "$until_ts" ] && return 1
    local now
    now=$(date +%s)
    if [ "$now" -lt "$until_ts" ]; then
        return 0   # 仍在暂停期
    fi
    # 已过期：清理掉 pause 文件
    rm -f "$pause_file" 2>/dev/null
    return 1
}

# ----------------------------------------------------------------------------
# 全局 STOP 检查（v3.2）：.stop 文件存在则无条件停止注入
# v3.5: 路径惰性求值
# ----------------------------------------------------------------------------
is_inject_stopped() {
    local stop_file="${MEMORY_BASE:-$HOME/.claude/mcMemories}/.stop"
    [ -f "$stop_file" ]
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
# v3.3: mcm-meta 元数据行 —— source/evidence → 权重（防幻觉折扣）
meta_re = re.compile(r'^<!-- mcm-meta source=(\S+) evidence=(\S+) -->$')
SOURCE_W = {'user': 1.0, 'agent': 0.7, 'system': 0.5}
EVIDENCE_W = {'validated': 1.0, 'observed': 0.85, 'hypothesis': 0.6}
DEFAULT_W = SOURCE_W['agent'] * EVIDENCE_W['observed']  # 0.595

# BM25 数据结构
tf = defaultdict(lambda: defaultdict(int))     # tf[mem][kw] = 词频（header 命中 ×3）
doc_freq = defaultdict(int)                     # df[kw] = 包含该 kw 的记忆数
mem_length = defaultdict(int)                   # mem[mem] = 总字符数
max_weight = defaultdict(lambda: DEFAULT_W)      # mem → 最大 chunk 权重（best evidence wins）
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
            else:
                mm = meta_re.match(line)
                if mm:
                    # 元数据行：算该 chunk 权重，取记忆内最大值（best evidence wins）
                    s, e = mm.group(1), mm.group(2)
                    w = SOURCE_W.get(s, SOURCE_W['agent']) * EVIDENCE_W.get(e, EVIDENCE_W['observed'])
                    if w > max_weight[current_mem]:
                        max_weight[current_mem] = w
                    # meta 行不计入 mem_length / tf
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
    # v3.3: 最终权重 × best evidence weight（best evidence wins，per memory）
    scores[mem] = score * max_weight[mem]

sorted_mems = sorted(scores.items(), key=lambda x: x[1], reverse=True)
# B5 (v3.1): 输出 "name<TAB>score"，让 prompt_submit 直接用 BM25 score 过门槛，
# 不再在调用方用 grep 二次打分（旧 0/3/1 双评分系统已下线）。
# v3.3: score 已乘以 source×evidence 权重（agent/observed 默认 ×0.595 折扣）。
for mem, sc in sorted_mems[:max_items]:
    print(f"{mem}\t{sc:.4f}")
PY
}

# ============================================================================
# 检查记忆是否在冷却期内
# ============================================================================

is_in_cooldown() {
    local memory_name="$1"
    local state_dir="${MEMORY_BASE:-$HOME/.claude/mcMemories}/.inject_state"
    local state_file="$state_dir/${memory_name}.last"

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
# v3.5: 路径惰性求值；mkdir 移到写时（不在 source 时建空目录）
mark_injected() {
    local memory_name="$1"
    local state_dir="${MEMORY_BASE:-$HOME/.claude/mcMemories}/.inject_state"
    mkdir -p "$state_dir"
    date +%s > "$state_dir/${memory_name}.last"
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

    # v3.2: 全局 STOP kill-switch（无条件，需显式 unstop）
    if is_inject_stopped; then
        log_injection "stopped" "" "" "session_start"
        return
    fi

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

    # v3.6: ledger open items 注入（确定性注入，不走 BM25/cooldown）
    if [ "${MCM_LEDGER_INJECT:-1}" = "1" ] && ! is_inject_stopped && ! is_inject_paused; then
        if [ -n "$project_dir" ] && [ -d "$project_dir" ] && command -v _ledger_inject_block &>/dev/null; then
            local ledger_block
            ledger_block=$(_ledger_inject_block "$project_dir")
            if [ -n "$ledger_block" ]; then
                output+="
$ledger_block
"
            fi
        fi
    fi

    echo "$output"
}

# ============================================================================
# User Prompt Submit: 智能检索 + 注入
# ============================================================================

prompt_submit_inject() {
    local user_prompt="$1"

    # v3.2: 全局 STOP kill-switch（无条件，需显式 unstop）
    if is_inject_stopped; then
        log_injection "stopped" "" "" "prompt_submit"
        return
    fi

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

    # 查找相关记忆（B5: 直接用 BM25 score，不再二次 grep 打分）
    # find_relevant_memories 输出 "name<TAB>score" 每行一条，已按 BM25 降序。
    local relevant=()
    declare -A mem_score=()
    while IFS=$'\t' read -r mem score; do
        [ -n "$mem" ] || continue
        relevant+=("$mem")
        mem_score["$mem"]="${score:-0}"
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

        # B5: 用 BM25 score 过门槛，替换旧 grep 0/3/1 双评分系统。
        # 旧实现把 find_relevant_memories 的 BM25 score 丢弃后再 grep 重打分，
        # 两套评分叠加会漂移；现统一为单一 BM25 评分。浮点比较交给 awk。
        local score="${mem_score[$mem]:-0}"
        if ! awk -v s="$score" -v m="$INJECT_BM25_MIN_SCORE" 'BEGIN{exit !(s+0 >= m+0)}'; then
            continue
        fi

        # 查找记忆路径
        local mem_path=$(find_memory_path "$mem" false 2>/dev/null)
        [ -z "$mem_path" ] && mem_path=$(find_memory_path "$mem" true 2>/dev/null)
        [ -z "$mem_path" ] && continue

        output+=$(format_injection "$mem" "$mem_path" "$score")
        mark_injected "$mem"
        log_injection "prompt_submit" "$mem" "$score" "$kw_csv"
        # v3.2: op-log（记忆级注入时间线，actor=hook）
        log_memory_op "$mem_path" "inject" "score=$score kw=$kw_csv" "hook"
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
        # v3.3: source=agent evidence=observed（AI 生成的会话摘要，默认折扣）
        {
            echo "---"
            echo "source_file: $notes_file"
            echo "created: $date_label"
            echo "type: session_summary"
            echo "source: agent"
            echo "evidence: observed"
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

        # v3.2: op-log（会话压缩归档时间线，actor=hook）
        log_memory_op "$project_dir" "precompact" "chunk=$chunk_name lines=$note_size" "hook"

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
