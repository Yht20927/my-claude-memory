#!/bin/bash
# ============================================================================
# mcmSync - 增量同步记忆 (v2.0)
# ============================================================================
# Usage: mcmSync [--workspace PATH] [--global] [--name NAME]
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
source "$LIB_DIR/core.sh"

WORKSPACE_DIR="$(pwd)"
IS_GLOBAL=false
MEMORY_NAME=""

# ----------------------------------------------------------------------------
# 参数解析
# ----------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --workspace)    WORKSPACE_DIR="$2"; shift 2 ;;
            --global)       IS_GLOBAL=true; shift ;;
            --name)         MEMORY_NAME="$2"; shift 2 ;;
            --help)         usage "用法: mcmSync [--workspace PATH] [--global] [--name NAME]" ;;
            *)              shift ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# Step 0: 健康检查
# ----------------------------------------------------------------------------

step0_health_check() {
    log "Step 0: 健康检查 - Checking L4 links..."

    local memory_dir="$1"
    local l4_dir="$memory_dir/.claude"

    if [ -d "$l4_dir" ]; then
        local result=$(check_l4_health "$l4_dir")
        local valid=$(echo "$result" | cut -d' ' -f1)
        local broken=$(echo "$result" | cut -d' ' -f2)
        local copy=$(echo "$result" | cut -d' ' -f3)
        log "  symlinks: ${valid} valid, ${broken} broken, ${copy} copies"
    else
        log "  No .claude directory (global memory or not initialized)"
    fi
}

# ----------------------------------------------------------------------------
# Step 1: Hash 比对（v2: 使用 workspace 相对路径）
# ----------------------------------------------------------------------------

step1_hash_comparison() {
    local memory_dir="$1"
    log "Step 1: Hash 比对 - Comparing file hashes..."

    local hash_file="$memory_dir/hash.json"
    if [ ! -f "$hash_file" ]; then
        log "  hash.json missing — cannot sync. Re-run mcmInit."
        echo ""
        return
    fi

    local changed_files=()

    # 从 hash.json 读取相对路径 key 列表
    while IFS= read -r rel_path; do
        [ -z "$rel_path" ] && continue
        local filepath="$WORKSPACE_DIR/$rel_path"
        if [ ! -f "$filepath" ]; then
            log "  Source file missing (deleted?): $rel_path"
            continue
        fi
        local new_hash=$(calculate_hash "$filepath")
        local old_hash=$(read_hash_value "$hash_file" "$rel_path")

        if [ "$new_hash" != "$old_hash" ]; then
            changed_files+=("$rel_path")
            log "  Changed: $rel_path"
        fi
    done < <(read_hash_keys "$hash_file")

    if [ ${#changed_files[@]} -eq 0 ]; then
        log "  No changes detected"
        echo ""
        return
    fi

    printf '%s\n' "${changed_files[@]}"
}

# ----------------------------------------------------------------------------
# Step 2: 增量重生成
# ----------------------------------------------------------------------------

step2_incremental_regen() {
    local memory_dir="$1"
    shift
    local changed_files=("$@")

    if [ ${#changed_files[@]} -eq 0 ]; then
        return
    fi

    log "Step 2: 增量重生成 - Regenerating changed chunks..."

    local chunks_dir="$memory_dir/chunks"
    local updated_sources=()

    # 收集所有需要更新的 chunk 信息（批量处理）
    local -a recreate_files=()
    local updates_json="{}"

    for rel_path in "${changed_files[@]}"; do
        local filepath="$WORKSPACE_DIR/$rel_path"
        if [ ! -f "$filepath" ]; then
            log "  Skipped (not found): $rel_path"
            continue
        fi

        local filename=$(basename "$filepath")
        local base="${filename%.*}"
        local chunk_file=$(ls "$chunks_dir"/[0-9]*_"${base}".md "$chunks_dir"/[0-9]*_"${base}"_[0-9]*.md 2>/dev/null | head -1)

        local mtime=$(get_mtime "$filepath")
        local hash=$(calculate_hash "$filepath")

        if [ -f "$chunk_file" ]; then
            # 收集到批量更新列表
            updates_json=$(printf '%s' "$updates_json" | $PYTHON -c "
import json, sys
data = json.loads(sys.stdin.read())
data[sys.argv[1]] = {'hash': sys.argv[2], 'mtime': sys.argv[3]}
print(json.dumps(data))
" "$chunk_file" "$hash" "$mtime" 2>/dev/null || echo "$updates_json")
            log "  Queued update: $(basename "$chunk_file")"
        else
            # chunk 被手动删除，标记需要重建
            recreate_files+=("${filepath}|${filename}|${base}|${mtime}|${hash}")
        fi

        updated_sources+=("$filepath")
    done

    # 批量更新已有 chunk 的 frontmatter（单次 Python 调用）
    if [ "$updates_json" != "{}" ]; then
        batch_update_chunk_frontmatter "$updates_json"
        log "  Batch frontmatter update done"
    fi

    # 重建被删除的 chunk
    for entry in "${recreate_files[@]}"; do
        IFS='|' read -r filepath filename base mtime hash <<< "$entry"
        local chunk_name="1_${base}.md"
        cat > "$chunks_dir/$chunk_name" <<CHUNK_EOF
---
source_file: $filepath
last_sync: $mtime
hash: $hash
---

# $filename

[待AI补充：浓缩内容]
CHUNK_EOF
        log "  Recreated chunk: $chunk_name"
    done

    # 重建完整 hash.json
    if [ -d "$chunks_dir" ]; then
        local all_sources=()
        for chunk in "$chunks_dir"/*.md; do
            [ -f "$chunk" ] || continue
            local source=$(grep '^source_file: ' "$chunk" 2>/dev/null | head -1 | sed 's/^source_file: //')
            [ -n "$source" ] && [ -f "$source" ] && all_sources+=("$source")
        done
        if [ ${#all_sources[@]} -gt 0 ]; then
            build_hash_json "$WORKSPACE_DIR" "${all_sources[@]}" > "$memory_dir/hash.json"
            log "  hash.json rebuilt"
        fi
    fi
}

# ----------------------------------------------------------------------------
# Step 3: 更新 L4 链接
# ----------------------------------------------------------------------------

step3_update_l4_links() {
    local memory_dir="$1"
    shift
    local changed_files=("$@")

    local l4_dir="$memory_dir/.claude"
    [ ! -d "$l4_dir" ] && return

    log "Step 3: 更新 L4 链接 - Updating changed source references..."

    for rel_path in "${changed_files[@]}"; do
        local filepath="$WORKSPACE_DIR/$rel_path"
        [ ! -f "$filepath" ] && continue
        create_l4_link "$filepath" "$l4_dir"
    done
}

# ----------------------------------------------------------------------------
# 主函数
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"

    local lock_name lock_token
    local memory_dir

    if [ "$IS_GLOBAL" = true ]; then
        if [ -z "$MEMORY_NAME" ]; then
            echo "同步全局记忆需指定 --name"
            echo "用法: mcmSync --global --name <记忆名称>"
            exit 1
        fi
        memory_dir=$(find_memory_path "$MEMORY_NAME" true)
        if [ -z "$memory_dir" ]; then
            log "未找到全局记忆: $MEMORY_NAME"
            exit 1
        fi
    else
        # B2 修复 (v3.1): 把 --name 透传给查找函数；未给 --name 时
        # find_project_memory_dir 会走 .workspace 标记扫描 + basename 回退。
        memory_dir=$(find_project_memory_dir "$WORKSPACE_DIR" "$MEMORY_NAME")
        if [ -z "$memory_dir" ]; then
            log "未找到项目记忆，请先运行 mcmInit"
            exit 1
        fi
    fi

    local mem_name=$(basename "$memory_dir")
    lock_name="sync_${mem_name}"
    lock_token=$(acquire_lock "$lock_name")
    mcm_on_exit "release_lock '$lock_name' '$lock_token'"

    log "开始增量同步: $mem_name"

    step0_health_check "$memory_dir"

    local changed_files=()
    while IFS= read -r file; do
        [ -n "$file" ] && changed_files+=("$file")
    done < <(step1_hash_comparison "$memory_dir")

    if [ ${#changed_files[@]} -eq 0 ]; then
        log "同步完成 - 无变化"
        release_lock "$lock_name" "$lock_token"
        mcm_clear_exit_handlers
        return
    fi

    step2_incremental_regen "$memory_dir" "${changed_files[@]}"
    step3_update_l4_links "$memory_dir" "${changed_files[@]}"

    # 增量更新搜索索引
    update_search_index "$mem_name" "$memory_dir" "$IS_GLOBAL"

    release_lock "$lock_name" "$lock_token"
    mcm_clear_exit_handlers

    log "增量同步完成，更新了 ${#changed_files[@]} 个文件"
}

mcm_run_command main "$@"
