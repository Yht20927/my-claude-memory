#!/bin/bash
# ============================================================================
# mcmInit - 初始化项目或个人记忆 (v2.0)
# ============================================================================
# Usage: mcmInit [--name NAME] [--tags TAGS] [--description DESC]
#                [--global] [--workspace PATH]
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
source "$LIB_DIR/core.sh"

IS_GLOBAL=false
MEMORY_NAME=""
TAGS=""
DESCRIPTION=""
WORKSPACE_DIR="$(pwd)"

# ----------------------------------------------------------------------------
# 参数解析
# ----------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --global)       IS_GLOBAL=true; shift ;;
            --name)         MEMORY_NAME="$2"; shift 2 ;;
            --tags)         TAGS="$2"; shift 2 ;;
            --description)  DESCRIPTION="$2"; shift 2 ;;
            --workspace)    WORKSPACE_DIR="$2"; shift 2 ;;
            --help)         usage "用法: mcmInit [--name NAME] [--tags TAGS] [--description DESC] [--global] [--workspace PATH]" ;;
            *)              shift ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# Step 1: 深度阅读
# ----------------------------------------------------------------------------

step1_deep_read() {
    log "Step 1: 深度阅读 - Reading source files..."

    local source_files=()
    while IFS= read -r file; do
        if [ -n "$file" ]; then
            source_files+=("$file")
            log "  Found: $file"
        fi
    done < <(detect_source_files "$WORKSPACE_DIR" || true)

    if [ ${#source_files[@]} -eq 0 ]; then
        log "  No source files found."
        echo ""
        echo "未检测到源文件 (CLAUDE.md, MEMORY.md, package.json 等)。"
        echo "建议先创建 CLAUDE.md 文件来描述项目。"
        echo ""
        if [ -t 0 ]; then
            echo "是否创建模板 CLAUDE.md？(y/n):"
            read -r answer
            if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
                local template_path="$WORKSPACE_DIR/CLAUDE.md"
                cat > "$template_path" <<'TEMPLATE_EOF'
# CLAUDE.md

This file provides guidance to Claude Code when working in this repository.

## Project overview

<!-- Describe your project in 1-2 sentences -->

## Commands

<!-- Build, test, lint commands -->

## Architecture

<!-- Key architectural patterns -->
TEMPLATE_EOF
                log "Created template: $template_path"
                source_files+=("$template_path")
            fi
        fi
    fi

    printf '%s\n' "${source_files[@]}"
}

# ----------------------------------------------------------------------------
# Step 2: 生成大纲 (L2)
# ----------------------------------------------------------------------------

step2_generate_outline() {
    local project_dir="$1"
    shift
    local source_files=("$@")

    local index_path="$project_dir/index.md"
    cat > "$index_path" <<'INDEX_EOF'
# L2 大纲索引
INDEX_EOF
    echo "" >> "$index_path"

    local chunk_num=1
    for file in "${source_files[@]}"; do
        local filename=$(basename "$file")
        local line_count=$(wc -l < "$file" 2>/dev/null || echo 0)
        # 检测文件类型
        local ext="${filename##*.}"
        local file_type="md"
        [ "$ext" != "md" ] && file_type="$ext"

        if [ "$line_count" -gt "$CHUNK_SPLIT_THRESHOLD" ]; then
            echo "" >> "$index_path"
            echo "## $filename (${line_count} lines, split)" >> "$index_path"
            echo "- **type**: $file_type | **split**: true | **lines**: 1-${line_count}" >> "$index_path"
        else
            echo "" >> "$index_path"
            echo "## $filename" >> "$index_path"
            echo "- **${chunk_num}_${filename%.*}.md** | type: $file_type | tags: [general] | lines: 1-${line_count}" >> "$index_path"
            echo "  > 源文件内容摘要" >> "$index_path"
        fi
        log "  Generated outline: $filename"
        chunk_num=$((chunk_num + 1))
    done

    log "  L2 index.md written to: $index_path"
}

# ----------------------------------------------------------------------------
# Step 3: 生成 L3 chunks + hash.json
# ----------------------------------------------------------------------------

step3_generate_chunks() {
    local project_dir="$1"
    shift
    local source_files=("$@")

    local chunks_dir="$project_dir/chunks"
    local chunk_map=()
    local chunk_num=1

    # 第一遍：调用 split_source_file 收集结果 + 去重源文件
    # 缓存输出行以便第二遍重放（避免二次 split）
    local all_sources=()
    declare -A split_map
    local cached_lines=()  # 缓存 chunk_name|source_file 行
    for file in "${source_files[@]}"; do
        while IFS='|' read -r chunk_name source; do
            [ -z "$chunk_name" ] && continue
            split_map["$chunk_name"]="$source"
            all_sources+=("$source")
            cached_lines+=("${chunk_name}|${source}")
        done < <(split_source_file "$file" "$chunks_dir" "$chunk_num")
    done

    # 批量获取所有源文件的 hash + mtime（单次 Python 调用）
    local unique_sources=()
    declare -A seen
    for s in "${all_sources[@]}"; do
        [ -n "${seen[$s]}" ] && continue
        seen[$s]=1
        unique_sources+=("$s")
    done

    local info_json="{}"
    if [ ${#unique_sources[@]} -gt 0 ]; then
        info_json=$(batch_file_info "${unique_sources[@]}")
    fi

    # 第二遍：从缓存重放，逐 chunk 生成/更新
    for entry in "${cached_lines[@]}"; do
        IFS='|' read -r chunk_name source <<< "$entry"
        [ -z "$chunk_name" ] && continue

        local mtime=$(read_batch_info "$info_json" "$source" "mtime")
        local hash=$(read_batch_info "$info_json" "$source" "hash")

        local chunk_path="$chunks_dir/$chunk_name"
        if [ -f "$chunk_path" ] && [ -s "$chunk_path" ]; then
            # split_source_file 已经为大文件写入了 frontmatter + 内容
            # 仅更新 frontmatter 中的 hash / last_sync / source_file 字段
            $PYTHON -c "
import re, sys
path = sys.argv[1]
source = sys.argv[2]
mtime = sys.argv[3]
hash_val = sys.argv[4]
with open(path, 'r') as f:
    content = f.read()
content = re.sub(r'^source_file: .*', f'source_file: {source}', content, flags=re.MULTILINE)
content = re.sub(r'^last_sync: .*', f'last_sync: {mtime}', content, flags=re.MULTILINE)
content = re.sub(r'^hash: .*', f'hash: {hash_val}', content, flags=re.MULTILINE)
with open(path, 'w') as f:
    f.write(content)
" "$chunk_path" "$source" "$mtime" "$hash" 2>/dev/null
        else
            # 小文件: split_source_file 只返回了名称，需从头创建 chunk
            cat > "$chunk_path" <<CHUNK_EOF
---
source_file: $source
last_sync: $mtime
hash: $hash
source: agent
evidence: observed
---

# $(basename "$source")

[待AI补充：浓缩内容]
CHUNK_EOF
        fi

        log "  Generated chunk: $chunk_name"
        chunk_map+=("$source")
        chunk_num=$((chunk_num + 1))
    done

    # 生成 hash.json（使用 workspace 相对路径）
    if [ ${#chunk_map[@]} -gt 0 ]; then
        build_hash_json "$WORKSPACE_DIR" "${chunk_map[@]}" > "$project_dir/hash.json"
        log "  hash.json written"
    fi
}

# ----------------------------------------------------------------------------
# Step 4: 创建 L4 链接/引用（仅项目，使用相对路径）
# ----------------------------------------------------------------------------

step4_create_l4_links() {
    local project_dir="$1"
    shift
    local source_files=("$@")

    for file in "${source_files[@]}"; do
        record_l4_source "$project_dir" "$file"
    done
}

# ----------------------------------------------------------------------------
# 主函数
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"

    # 检测项目名
    if [ -z "$MEMORY_NAME" ]; then
        if [ "$IS_GLOBAL" = true ]; then
            echo "请指定记忆名称 (--name):"
            read -r MEMORY_NAME
        else
            MEMORY_NAME=$(basename "$(get_git_root)" 2>/dev/null || basename "$(pwd)")
        fi
    fi

    # 检测标签
    if [ -z "$TAGS" ]; then
        if [ "$IS_GLOBAL" = true ]; then
            TAGS="auto"
        else
            TAGS="tools"
        fi
    fi

    # 默认描述
    if [ -z "$DESCRIPTION" ]; then
        if [ "$IS_GLOBAL" = true ]; then
            DESCRIPTION="个人记忆: $MEMORY_NAME"
        else
            DESCRIPTION="项目记忆: $MEMORY_NAME"
        fi
    fi

    log "开始初始化记忆: $MEMORY_NAME (tags: $TAGS, global: $IS_GLOBAL)"

    # 拆分主标签：仅第一个标签作为物理目录，其余写入 summary.md
    # 这样既避免 "tag1,tag2,tag3" 整串变成目录名（污染 get_project_tags），
    # 又保留多标签语义供 L2 索引和 summary 使用。
    local default_tag="tools"
    [ "$IS_GLOBAL" = true ] && default_tag="auto"
    local primary_tag
    primary_tag=$(parse_primary_tag "$TAGS" "$default_tag")
    if [ "$primary_tag" != "$TAGS" ]; then
        log "  主标签: $primary_tag（完整 tags: $TAGS 写入 summary.md）"
    fi

    # 并发锁
    local lock_name="init_${MEMORY_NAME}"
    local lock_token=$(acquire_lock "$lock_name")
    mcm_on_exit "release_lock '$lock_name' '$lock_token'"

    # Step 1: 深度阅读
    local source_files=()
    while IFS= read -r file; do
        [ -n "$file" ] && source_files+=("$file")
    done < <(step1_deep_read)

    # 创建目录结构（使用主标签）
    local memory_path
    if [ "$IS_GLOBAL" = true ]; then
        memory_path=$(create_global_structure "$primary_tag" "$MEMORY_NAME")
    else
        memory_path=$(create_project_structure "$primary_tag" "$MEMORY_NAME")
    fi
    log "  Created memory structure: $memory_path"

    # B2 修复 (v3.1): 记录 workspace origin，让后续 mcmSync / PreCompact /
    # session_start（不带 --name 时）能凭标记找到 --name 与目录名不同的项目记忆。
    # 仅项目记忆需要（全局记忆不绑定 workspace）。
    if [ "$IS_GLOBAL" = false ]; then
        local _ws_origin
        _ws_origin=$(git -C "$WORKSPACE_DIR" rev-parse --show-toplevel 2>/dev/null || resolve_path "$WORKSPACE_DIR")
        [ -n "$_ws_origin" ] && printf '%s\n' "$_ws_origin" > "$memory_path/.workspace"
    fi

    # 创建 summary.md（写入完整 tags 字符串，便于多 tag 检索）
    generate_summary_md "$MEMORY_NAME" "$DESCRIPTION" "$TAGS" > "$memory_path/summary.md"

    if [ ${#source_files[@]} -gt 0 ]; then
        # Step 2: 生成大纲
        step2_generate_outline "$memory_path" "${source_files[@]}"

        # Step 3: 生成 chunks + hash.json
        step3_generate_chunks "$memory_path" "${source_files[@]}"

        # Step 4: 创建 L4 链接（仅项目）
        if [ "$IS_GLOBAL" = false ]; then
            step4_create_l4_links "$memory_path" "${source_files[@]}"
        fi
    else
        log "  No source files found, creating minimal chunk for L3"
        # 为无源文件的全局记忆创建基本 L3 chunk
        local chunk_path="$memory_path/chunks/1_${MEMORY_NAME}.md"
        cat > "$chunk_path" <<CHUNK_EOF
---
source_file: ""
created: $(date '+%Y-%m-%d')
source: agent
evidence: observed
---

# $MEMORY_NAME

$DESCRIPTION

[待AI补充：浓缩内容]
CHUNK_EOF
        log "  Created minimal chunk: $chunk_path"
    fi

    # 更新全局索引（注意：传主标签而非原始 TAGS）
    if [ "$IS_GLOBAL" = false ]; then
        update_global_index "project" "$primary_tag" "$MEMORY_NAME" "$memory_path" "add"
    else
        update_global_index "global" "$primary_tag" "$MEMORY_NAME" "$memory_path" "add"
    fi

    # 增量更新搜索索引
    update_search_index "$MEMORY_NAME" "$memory_path" "$IS_GLOBAL"

    # v3.2: op-log
    log_memory_op "$memory_path" "init" "tags=$TAGS sources=${#source_files[@]} global=$IS_GLOBAL" "user"

    # 释放锁
    release_lock "$lock_name" "$lock_token"
    mcm_clear_exit_handlers

    log "初始化完成: $memory_path"

    # 提示 AI 补充 L3 浓缩内容
    if [ ${#source_files[@]} -gt 0 ]; then
        echo ""
        echo "============================================"
        echo "  init 完成。下一步建议:"
        echo "  1. 运行 mcmSync 确保记忆最新"
        echo "  2. AI 应读取各 source file 并生成 L3 chunk 浓缩内容"
        echo "     (chunks 位于: $memory_path/chunks/)"
        echo "============================================"
    fi
}

mcm_run_command main "$@"
