#!/bin/bash
# ============================================================================
# mcMemory-lib - 共享工具库 (v2.0)
# ============================================================================
#
# v2.0 改进:
#   - hash.json 使用相对路径 (workspace → source file)，不再只用 basename
#   - Python 内联脚本统一通过 sys.argv 传参，消除注入风险
#   - 新增 resolve_path() 替代裸调 realpath，兼容 macOS
#   - 标签系统从硬编码改为动态发现
#   - L4 链接优先使用相对路径
#   - 新增 flock / mkdir 并发锁
#   - 扩展源文件检测支持非 .md 文件
#   - 大文件自动按标题拆分
#   - 搜索索引支持
# ============================================================================

# Configuration
MEMORY_BASE="${MEMORY_BASE:-$HOME/.claude/mcMemories}"
PROJECTS_DIR="$MEMORY_BASE/projects"
GLOBAL_DIR="$MEMORY_BASE/global"
TRASH_DIR="$MEMORY_BASE/.trash"
LOCK_DIR_BASE="$MEMORY_BASE/.locks"
SEARCH_INDEX="$MEMORY_BASE/.search_index"

# 大文件拆分阈值（行数）
CHUNK_SPLIT_THRESHOLD="${CHUNK_SPLIT_THRESHOLD:-200}"

# Python 自动检测（兼容 $PYTHON / python / py）
PYTHON=""
for cmd in $PYTHON python py python3; do
    if command -v "$cmd" &>/dev/null; then
        PYTHON="$cmd"
        break
    fi
done
if [ -z "$PYTHON" ]; then
    for p in /usr/bin/python3 /usr/bin/python /c/mydir/Python311/python.exe; do
        [ -x "$p" ] && { PYTHON="$p"; break; }
    done
fi

# ============================================================================
# 日志函数
# ============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

error() {
    echo "ERROR: $1" >&2
    exit 1
}

usage() {
    echo "$1"
    exit 0
}

# ============================================================================
# 路径解析（跨平台，替代裸调 realpath）
# ============================================================================

resolve_path() {
    local path="$1"
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        echo "$path"
        return
    fi
    if command -v realpath &>/dev/null; then
        realpath "$path" 2>/dev/null || echo "$path"
    else
        $PYTHON -c "import os, sys; print(os.path.realpath(os.path.abspath(sys.argv[1])))" "$path" 2>/dev/null || echo "$path"
    fi
}

# 计算从 base 目录到 target 文件的相对路径
calculate_relative_path() {
    local base_dir="$1"
    local target="$2"
    $PYTHON -c "
import os, sys
base = os.path.abspath(sys.argv[1])
target = os.path.abspath(sys.argv[2])
try:
    rel = os.path.relpath(target, base)
    print(rel.replace(os.sep, '/'))
except ValueError:
    print(target.replace(os.sep, '/'))
" "$base_dir" "$target" 2>/dev/null || echo "$target"
}

# ============================================================================
# 并发锁（优先 flock，回退到 mkdir 互斥锁）
# ============================================================================

acquire_lock() {
    local name="$1"
    mkdir -p "$LOCK_DIR_BASE"
    local lock_file="$LOCK_DIR_BASE/${name}.lock"
    local lock_dir="$LOCK_DIR_BASE/${name}.lock.d"

    if command -v flock &>/dev/null; then
        # 使用 bash 自动分配 fd（避免 RANDOM 碰撞和 eval 注入）
        local fd
        exec {fd}>"$lock_file"
        if flock -w 10 "$fd" 2>/dev/null; then
            echo "flock:$fd:$lock_file"
            return 0
        fi
        exec {fd}>&-
        return 1
    fi

    # 回退: mkdir 原子性互斥锁
    local waited=0
    while ! mkdir "$lock_dir" 2>/dev/null; do
        sleep 0.5
        waited=$((waited + 1))
        if [ $waited -ge 20 ]; then
            error "获取锁超时: $name"
        fi
    done
    echo "mkdir:$lock_dir"
    return 0
}

release_lock() {
    local name="$1"
    local lock_token="$2"

    if [[ "$lock_token" == flock:* ]]; then
        local fd="${lock_token#flock:}"
        fd="${fd%%:*}"
        eval "exec $fd>&-" 2>/dev/null
        rm -f "$LOCK_DIR_BASE/${name}.lock" 2>/dev/null
    elif [[ "$lock_token" == mkdir:* ]]; then
        rmdir "${lock_token#mkdir:}" 2>/dev/null
    fi
}

# ============================================================================
# Git 相关
# ============================================================================

is_git_project() {
    git rev-parse --is-inside-work-tree 2>/dev/null
}

get_git_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

# ============================================================================
# Hash 计算（跨平台，sys.argv 传参防注入）
# ============================================================================

calculate_hash() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo ""
        return
    fi

    if command -v sha256sum &>/dev/null; then
        sha256sum "$file" | cut -d' ' -f1
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$file" | cut -d' ' -f1
    else
        $PYTHON -c "
import sys, hashlib
with open(sys.argv[1], 'rb') as f:
    print(hashlib.sha256(f.read()).hexdigest())
" "$file" 2>/dev/null
    fi
}

# ============================================================================
# 文件时间（sys.argv 传参防注入）
# ============================================================================

get_mtime() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo ""
        return
    fi
    $PYTHON -c "
import os, datetime, sys
try:
    mtime = os.path.getmtime(sys.argv[1])
    print(datetime.datetime.fromtimestamp(mtime).strftime('%Y-%m-%dT%H:%M:%S'))
except:
    print('')
" "$file" 2>/dev/null
}

# ============================================================================
# 批量文件信息（单次 Python 调用，替代逐个 get_mtime + calculate_hash）
# ============================================================================

batch_file_info() {
    if [ $# -eq 0 ]; then
        echo "{}"
        return
    fi
    $PYTHON -c "
import json, sys, os, hashlib, datetime
files = sys.argv[1:]
data = {}
for f in files:
    info = {}
    try:
        if os.path.isfile(f):
            with open(f, 'rb') as fh:
                info['hash'] = hashlib.sha256(fh.read()).hexdigest()
            mtime = os.path.getmtime(f)
            info['mtime'] = datetime.datetime.fromtimestamp(mtime).strftime('%Y-%m-%dT%H:%M:%S')
        else:
            info['hash'] = ''
            info['mtime'] = ''
    except:
        info['hash'] = ''
        info['mtime'] = ''
    data[f] = info
print(json.dumps(data))
" "$@" 2>/dev/null
}

read_batch_info() {
    local json="$1"
    local file="$2"
    local field="$3"
    $PYTHON -c "
import json, sys
data = json.loads(sys.argv[1])
entry = data.get(sys.argv[2], {})
print(entry.get(sys.argv[3], ''))
" "$json" "$file" "$field" 2>/dev/null
}

# ============================================================================
# sed 安全转义
# ============================================================================

sed_escape() {
    printf '%s' "$1" | sed -e 's/[][\\.*^$+?{}()|]/\\&/g'
}

# ============================================================================
# sed -i 跨平台兼容（macOS BSD sed 需要 -i ''）
# ============================================================================

sed_i() {
    local expression="$1"
    local file="$2"
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "$expression" "$file"
    else
        sed -i '' "$expression" "$file"
    fi
}

# ============================================================================
# 源文件检测（支持 .md 及常见配置文件）
# ============================================================================

# 可覆盖的额外源文件匹配模式
SOURCE_PATTERNS="${SOURCE_PATTERNS:-}"

detect_source_files() {
    local workspace="$1"
    local files=()

    # Markdown 源文件
    for file in "CLAUDE.md" "MEMORY.md" "memory.md" "CONTEXT.md"; do
        if [ -f "$workspace/$file" ]; then
            files+=("$workspace/$file")
        fi
    done

    # .claude/ 目录下的 .md 文件
    if [ -d "$workspace/.claude" ]; then
        for file in "$workspace/.claude"/*.md; do
            if [ -f "$file" ]; then
                files+=("$file")
            fi
        done
    fi

    # 常见项目配置文件（自动检测）
    for pattern in "package.json" "Makefile" "docker-compose.yml" "docker-compose.yaml" \
                   ".env.example" "pyproject.toml" "Cargo.toml" "go.mod" "CMakeLists.txt"; do
        if [ -f "$workspace/$pattern" ]; then
            files+=("$workspace/$pattern")
        fi
    done

    # 用户自定义模式
    if [ -n "$SOURCE_PATTERNS" ]; then
        for pattern in $SOURCE_PATTERNS; do
            for f in "$workspace"/$pattern; do
                [ -f "$f" ] && files+=("$f")
            done
        done
    fi

    if [ ${#files[@]} -gt 0 ]; then
        printf '%s\n' "${files[@]}"
    fi
}

# ============================================================================
# 记忆类型检测（动态标签发现）
# ============================================================================

detect_memory_type() {
    local name="$1"

    for tag in $(get_project_tags); do
        if [ -d "$PROJECTS_DIR/$tag/$name" ]; then
            echo "project"
            return
        fi
    done

    for mode in $(get_global_modes); do
        if [ -d "$GLOBAL_DIR/$mode/$name" ]; then
            echo "global"
            return
        fi
    done

    echo "unknown"
}

# 动态获取项目标签列表
get_project_tags() {
    if [ -d "$PROJECTS_DIR" ]; then
        local d
        for d in "$PROJECTS_DIR"/*/; do
            [ -d "$d" ] || continue
            basename "$d"
        done
    fi
}

# 动态获取全局模式列表
get_global_modes() {
    if [ -d "$GLOBAL_DIR" ]; then
        local d
        for d in "$GLOBAL_DIR"/*/; do
            [ -d "$d" ] || continue
            basename "$d"
        done
    fi
}

# ============================================================================
# 全局索引操作
# ============================================================================

ensure_index_file() {
    local type="$1"
    local index_file

    if [ "$type" = "project" ]; then
        index_file="$PROJECTS_DIR/index.md"
        [ ! -d "$PROJECTS_DIR" ] && mkdir -p "$PROJECTS_DIR"
    else
        index_file="$GLOBAL_DIR/index.md"
        [ ! -d "$GLOBAL_DIR" ] && mkdir -p "$GLOBAL_DIR"
    fi

    if [ ! -f "$index_file" ]; then
        if [ "$type" = "project" ]; then
            echo "# 项目记忆索引" > "$index_file"
            echo "" >> "$index_file"
        else
            echo "# 个人记忆索引" > "$index_file"
            echo "" >> "$index_file"
        fi
    fi

    echo "$index_file"
}

update_global_index() {
    local type="$1"
    local tag="$2"
    local name="$3"
    local path="$4"
    local action="$5"

    local index_file
    local entry

    if [ "$type" = "project" ]; then
        index_file=$(ensure_index_file "project")
        entry="- [$name] | path: $tag/$name/index.md"
    else
        index_file=$(ensure_index_file "global")
        local rel_path="${path#$GLOBAL_DIR/}"
        entry="- [$name] | path: $rel_path/index.md"
    fi

    case "$action" in
        add)
            if grep -Fq "[$name]" "$index_file" 2>/dev/null; then
                log "Entry already exists: $name"
            else
                echo "$entry" >> "$index_file"
                log "Added to index: $name"
            fi
            ;;
        remove)
            local safe_name=$(sed_escape "$name")
            sed_i "/\[$safe_name\]/d" "$index_file"
            log "Removed from index: $name"
            ;;
    esac
}

# ============================================================================
# 行号范围
# ============================================================================
# L4 健康检查
# ============================================================================

check_l4_health() {
    local l4_dir="$1"
    local valid=0
    local broken=0
    local copy=0

    if [ ! -d "$l4_dir" ]; then
        echo "0 0 0"
        return
    fi

    for link in "$l4_dir"/*; do
        [ -f "$link" ] || [ -L "$link" ] || continue
        if [ -L "$link" ]; then
            if [ -e "$link" ]; then
                valid=$((valid + 1))
            else
                broken=$((broken + 1))
            fi
        elif [[ "$link" == *.source ]]; then
            local target=$(cat "$link" 2>/dev/null)
            # 相对路径需基于 .source 文件所在目录解析
            if [[ "$target" != /* ]]; then
                target="$(dirname "$link")/$target"
            fi
            if [ -e "$target" ]; then
                valid=$((valid + 1))
            else
                broken=$((broken + 1))
            fi
        else
            copy=$((copy + 1))
        fi
    done

    echo "$valid $broken $copy"
}

# ============================================================================
# L4 链接创建（优先相对路径，Windows 兼容降级）
# ============================================================================

create_l4_link() {
    local source_file="$1"
    local link_dir="$2"

    mkdir -p "$link_dir"

    local filename=$(basename "$source_file")
    local link_path="$link_dir/$filename"

    # 清除旧的
    rm -f "$link_path" "$link_path.source" 2>/dev/null

    # 计算相对于 link_dir 的源文件路径
    local rel_path=$(calculate_relative_path "$link_dir" "$source_file")

    # 尝试 symlink（优先相对路径）
    ln -sf "$rel_path" "$link_path" 2>/dev/null

    if [ -L "$link_path" ] && [ -e "$link_path" ]; then
        log "  Created L4 symlink: $filename (→ $rel_path)"
    else
        # Windows 降级: .source 引用文件也存相对路径
        rm -f "$link_path" 2>/dev/null
        echo "$rel_path" > "$link_path.source"
        log "  Created L4 reference: $filename.source (symlink unavailable)"
    fi
}

# ============================================================================
# Hash.json 构建（v2: key 使用相对路径而非 basename）
# ============================================================================

build_hash_json() {
    local workspace="$1"
    shift
    local source_files=("$@")

    if [ ${#source_files[@]} -eq 0 ]; then
        echo "{}"
        return
    fi

    # 构建 path:hash 映射，key 为 workspace 相对路径
    $PYTHON -c "
import json, sys, hashlib, os, datetime
workspace = os.path.abspath(sys.argv[1])
files = sys.argv[2:]
data = {}
for f in files:
    try:
        with open(f, 'rb') as fh:
            h = hashlib.sha256(fh.read()).hexdigest()
    except:
        h = ''
    abs_f = os.path.abspath(f)
    try:
        rel = os.path.relpath(abs_f, workspace).replace(os.sep, '/')
    except ValueError:
        rel = os.path.basename(f)
    try:
        mtime = datetime.datetime.fromtimestamp(os.path.getmtime(abs_f)).strftime('%Y-%m-%dT%H:%M:%S')
    except:
        mtime = ''
    data[rel] = {'hash': h, 'mtime': mtime}
print(json.dumps(data, indent=2))
" "$workspace" "${source_files[@]}" 2>/dev/null
}

# ============================================================================
# 读取 hash.json 并返回 key 列表（供 sync 使用）
# ============================================================================

read_hash_keys() {
    local hash_file="$1"
    $PYTHON -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for k in data:
    print(k)
" "$hash_file" 2>/dev/null
}

read_hash_value() {
    local hash_file="$1"
    local key="$2"
    $PYTHON -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(data.get(sys.argv[2], {}).get('hash', ''))
" "$hash_file" "$key" 2>/dev/null
}

# ============================================================================
# 批量更新 chunk frontmatter（单次 Python 调用）
# 参数: JSON 字符串，格式 {"chunk_path": {"hash": "...", "mtime": "..."}, ...}
# ============================================================================

batch_update_chunk_frontmatter() {
    local updates_json="$1"
    $PYTHON -c "
import re, json, sys
updates = json.loads(sys.argv[1])
for path, info in updates.items():
    try:
        with open(path, 'r') as f:
            content = f.read()
        h = info.get('hash', '')
        m = info.get('mtime', '')
        if h:
            content = re.sub(r'^hash: .*', f'hash: {h}', content, flags=re.MULTILINE)
        if m:
            content = re.sub(r'^last_sync: .*', f'last_sync: {m}', content, flags=re.MULTILINE)
        with open(path, 'w') as f:
            f.write(content)
    except:
        pass
" "$updates_json" 2>/dev/null
}

# ============================================================================
# 大文件按 Markdown 标题自动拆分
# ============================================================================

split_source_file() {
    local source_file="$1"
    local chunks_dir="$2"
    local prefix="$3"  # chunk 编号前缀，如 "1"

    local filename=$(basename "$source_file")
    local base="${filename%.*}"

    # 检测是否为大文件
    local line_count=$(wc -l < "$source_file" 2>/dev/null || echo 0)

    if [ "$line_count" -le "$CHUNK_SPLIT_THRESHOLD" ]; then
        # 小文件: 返回单行，格式: chunk_name|source_file
        echo "${prefix}_${base}.md|$source_file"
        return
    fi

    # 大文件: 按 ## 标题拆分（用数组收集行，避免 O(n²) 字符串拼接）
    log "  Splitting large file ($line_count lines): $filename"

    local sub_idx=1
    local -a chunk_lines=()
    local current_heading=""

    flush_chunk() {
        if [ -n "$current_heading" ] && [ ${#chunk_lines[@]} -gt 0 ]; then
            local chunk_name="${prefix}_${base}_${sub_idx}.md"
            {
                echo "---"
                echo "source_file: $source_file"
                echo "section: $current_heading"
                echo "---"
                echo ""
                printf '%s\n' "${chunk_lines[@]}"
            } > "$chunks_dir/$chunk_name"
            echo "${chunk_name}|$source_file"
            sub_idx=$((sub_idx + 1))
            chunk_lines=()
        fi
    }

    while IFS= read -r line; do
        if [[ "$line" =~ ^##[^#] ]]; then
            flush_chunk
            current_heading="${line#\#\# }"
        fi
        chunk_lines+=("$line")
    done < "$source_file"

    # 保存最后一个 chunk
    flush_chunk
}

# ============================================================================
# 目录结构创建
# ============================================================================

create_project_structure() {
    local tag="$1"
    local name="$2"
    local base_dir="$PROJECTS_DIR/$tag/$name"

    mkdir -p "$base_dir/chunks"
    mkdir -p "$base_dir/.claude"

    echo "$base_dir"
}

create_global_structure() {
    local mode="$1"
    local category="$2"
    local base_dir="$GLOBAL_DIR/$mode/$category"

    mkdir -p "$base_dir/chunks"

    echo "$base_dir"
}

# ============================================================================
# Summary.md 生成
# ============================================================================

generate_summary_md() {
    local name="$1"
    local description="$2"
    local tags="${3:-}"

    cat <<EOF
# $name
$description
EOF
    if [ -n "$tags" ]; then
        echo "tags: $tags"
    fi
}

# ============================================================================
# 标签拆分：将 "tag1, tag2, tag3" 形式拆出主标签（用于物理目录）
# 主标签做了过滤：仅保留 [a-zA-Z0-9_-]，回退到 tools/auto。
# ============================================================================

parse_primary_tag() {
    local tags="$1"
    local default_tag="${2:-tools}"

    local primary
    primary=$(echo "$tags" | cut -d',' -f1 | xargs)
    # 清洗：仅允许字母数字下划线连字符，其他字符替换为 _
    primary=$(echo "$primary" | tr -c '[:alnum:]_-' '_' | sed 's/^_*//;s/_*$//')
    if [ -z "$primary" ]; then
        primary="$default_tag"
    fi
    echo "$primary"
}

# ============================================================================
# 查找项目记忆目录（通过 git root 名称）
# ============================================================================

find_project_memory_dir() {
    local workspace="$1"
    local project_name=$(basename "$(git -C "$workspace" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)

    if [ -z "$project_name" ]; then
        echo ""
        return
    fi

    for tag in $(get_project_tags); do
        local dir="$PROJECTS_DIR/$tag/$project_name"
        if [ -d "$dir" ]; then
            echo "$dir"
            return
        fi
    done

    echo ""
}

# ============================================================================
# 通过 git root 查找项目记忆的 tag
# ============================================================================

find_project_tag() {
    local workspace="$1"
    local project_name=$(basename "$(git -C "$workspace" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)

    if [ -z "$project_name" ]; then
        echo ""
        return
    fi

    for tag in $(get_project_tags); do
        if [ -d "$PROJECTS_DIR/$tag/$project_name" ]; then
            echo "$tag"
            return
        fi
    done

    echo ""
}

# ============================================================================
# 查找记忆路径（通过名称和类型，动态标签发现）
# ============================================================================

find_memory_path() {
    local name="$1"
    local is_global="$2"

    if [ "$is_global" = true ]; then
        for mode in $(get_global_modes); do
            local path="$GLOBAL_DIR/$mode/$name"
            if [ -d "$path" ]; then
                echo "$path"
                return
            fi
        done
    else
        for tag in $(get_project_tags); do
            local path="$PROJECTS_DIR/$tag/$name"
            if [ -d "$path" ]; then
                echo "$path"
                return
            fi
        done
    fi

    echo ""
}

# ============================================================================
# 安全删除（校验路径前缀防误删）
# ============================================================================

safe_rm() {
    local path="$1"
    case "$path" in
        "$MEMORY_BASE"/*)
            rm -rf "$path"
            ;;
        *)
            error "拒绝删除: $path (不在 $MEMORY_BASE 范围内)"
            ;;
    esac
}

# ============================================================================
# 回收站机制
# ============================================================================

move_to_trash() {
    local path="$1"
    local name="$2"

    mkdir -p "$TRASH_DIR"

    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local ns=$(date '+%N' 2>/dev/null || echo "$$")
    local trash_name="${name}_${timestamp}_${ns: -4}"
    local trash_path="$TRASH_DIR/$trash_name"

    # 如果仍碰撞，追加计数器
    if [ -d "$trash_path" ] || [ -f "$TRASH_DIR/.${trash_name}.origin" ]; then
        local i=1
        while [ -d "${trash_path}_${i}" ] || [ -f "$TRASH_DIR/.${trash_name}_${i}.origin" ]; do
            i=$((i + 1))
        done
        trash_name="${trash_name}_${i}"
        trash_path="$TRASH_DIR/$trash_name"
    fi

    # 记录原始路径以便恢复
    echo "$path" > "$TRASH_DIR/.${trash_name}.origin"

    mv "$path" "$trash_path" 2>/dev/null
    if [ $? -eq 0 ]; then
        log "Moved to trash: $trash_name"
        echo "$trash_path"
    else
        error "移至回收站失败: $path"
    fi
}

list_trash() {
    if [ ! -d "$TRASH_DIR" ]; then
        echo "（回收站为空）"
        return
    fi

    local found=0
    for origin_file in "$TRASH_DIR"/.*.origin; do
        [ -f "$origin_file" ] || continue
        local trash_name=$(basename "$origin_file" .origin)
        trash_name="${trash_name#.}"
        local origin_path=$(cat "$origin_file" 2>/dev/null)
        local trash_path="$TRASH_DIR/$trash_name"
        if [ -d "$trash_path" ]; then
            echo "  $trash_name → $origin_path"
            found=1
        fi
    done

    [ "$found" -eq 0 ] && echo "（回收站为空）"
}

restore_from_trash() {
    local trash_name="$1"
    local origin_file="$TRASH_DIR/.${trash_name}.origin"

    if [ ! -f "$origin_file" ]; then
        error "未找到回收站条目: $trash_name"
    fi

    local origin_path=$(cat "$origin_file")
    local trash_path="$TRASH_DIR/$trash_name"

    if [ ! -d "$trash_path" ]; then
        error "回收站目录不存在: $trash_path"
    fi

    local parent=$(dirname "$origin_path")
    mkdir -p "$parent"

    if [ -d "$origin_path" ]; then
        error "目标路径已存在: $origin_path"
    fi

    mv "$trash_path" "$origin_path"
    rm -f "$origin_file"
    log "Restored: $origin_path"
}

empty_trash() {
    if [ -d "$TRASH_DIR" ]; then
        rm -rf "$TRASH_DIR"
    fi
    mkdir -p "$TRASH_DIR"
    log "Trash emptied"
}

# ============================================================================
# 搜索索引管理
# ----------------------------------------------------------------------------
# v2.4: 原子写入策略
#   - 所有"整体重写"路径（rebuild / remove / update）走"写临时文件 +
#     mv 原子 rename"，读端永远看到完整的旧版或完整的新版，不会读到
#     half-written 状态。
#   - append_to_search_index 仍用 >> 追加。POSIX 规定 < PIPE_BUF (4096)
#     的写入原子；单 chunk 几 KB 在主流文件系统上也是单次 write(2)，
#     读端最多看到"少了几个新 chunk"而不是 corrupt。
# ============================================================================

# 把整个文本原子写入 $SEARCH_INDEX：写到同目录 .tmp 再 mv，避免读端撞上 half-write
_atomic_write_index() {
    local content="$1"
    local tmp="${SEARCH_INDEX}.tmp.$$"
    mkdir -p "$(dirname "$SEARCH_INDEX")"
    printf '%s' "$content" > "$tmp"
    mv -f "$tmp" "$SEARCH_INDEX"
}

# 从搜索索引中移除指定记忆的所有 sections（原子重写）
remove_from_search_index() {
    local memory_name="$1"
    local is_global="$2"

    if [ ! -f "$SEARCH_INDEX" ] || [ ! -s "$SEARCH_INDEX" ]; then
        return
    fi

    local prefix="===== $memory_name /"
    [ "$is_global" = true ] && prefix="===== [global] $memory_name /"

    local tmp="${SEARCH_INDEX}.tmp.$$"
    $PYTHON -c "
import sys
prefix = sys.argv[1]
src = sys.argv[2]
dst = sys.argv[3]

try:
    with open(src, 'r', errors='replace') as f:
        lines = f.readlines()
    kept = []
    skip = False
    for line in lines:
        if line.startswith('===== '):
            skip = line.startswith(prefix)
        if not skip:
            kept.append(line)
    with open(dst, 'w') as f:
        f.writelines(kept)
except Exception:
    sys.exit(1)
" "$prefix" "$SEARCH_INDEX" "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$SEARCH_INDEX" \
        || rm -f "$tmp"
}

# 将单个记忆的 chunks 追加到搜索索引末尾
# 注意：保持 append 语义以避免每次 sync 都全文重写大索引。
# 单 chunk 追加在常见文件系统上 write(2) 通常原子；读端最多看到"少几个 chunk"。
append_to_search_index() {
    local memory_path="$1"
    local is_global="$2"

    local memory_name=$(basename "$memory_path")
    local chunks_dir="$memory_path/chunks"

    if [ ! -d "$chunks_dir" ]; then
        return
    fi

    local prefix="===== $memory_name /"
    [ "$is_global" = true ] && prefix="===== [global] $memory_name /"

    mkdir -p "$(dirname "$SEARCH_INDEX")"

    # 收集所有 chunk 内容到临时文件，再一次性 cat >> 索引
    # （单 chunk 追加多次仍可能被并发读端撕裂；先合并后单次 append 缩小窗口）
    local buf="${SEARCH_INDEX}.append.$$"
    : > "$buf"
    for chunk in "$chunks_dir"/*.md; do
        [ -f "$chunk" ] || continue
        local chunk_name=$(basename "$chunk")
        {
            echo "$prefix $chunk_name ====="
            cat "$chunk"
            echo ""
        } >> "$buf"
    done
    if [ -s "$buf" ]; then
        cat "$buf" >> "$SEARCH_INDEX"
    fi
    rm -f "$buf"
}

# 增量更新搜索索引（移除旧 sections + 追加新内容）
update_search_index() {
    local memory_name="$1"
    local memory_path="$2"
    local is_global="${3:-false}"

    remove_from_search_index "$memory_name" "$is_global"
    append_to_search_index "$memory_path" "$is_global"
}

# 全量重建搜索索引（fallback，session-start 使用）
# v2.4: 写临时文件 + mv，避免读端撞上 half-written
rebuild_search_index() {
    log "Rebuilding search index..."
    mkdir -p "$(dirname "$SEARCH_INDEX")"
    local tmp="${SEARCH_INDEX}.tmp.$$"
    : > "$tmp"

    if [ -d "$PROJECTS_DIR" ]; then
        while IFS= read -r -d '' chunk; do
            local project_name=$(basename "$(dirname "$(dirname "$chunk")")")
            local chunk_name=$(basename "$chunk")
            echo "===== $project_name / $chunk_name =====" >> "$tmp"
            cat "$chunk" >> "$tmp"
            echo "" >> "$tmp"
        done < <(find "$PROJECTS_DIR" -name "*.md" -path "*/chunks/*" -print0 2>/dev/null)
    fi

    if [ -d "$GLOBAL_DIR" ]; then
        while IFS= read -r -d '' chunk; do
            local memory_name=$(basename "$(dirname "$(dirname "$chunk")")")
            local chunk_name=$(basename "$chunk")
            echo "===== [global] $memory_name / $chunk_name =====" >> "$tmp"
            cat "$chunk" >> "$tmp"
            echo "" >> "$tmp"
        done < <(find "$GLOBAL_DIR" -name "*.md" -path "*/chunks/*" -print0 2>/dev/null)
    fi

    mv -f "$tmp" "$SEARCH_INDEX"
    log "Search index rebuilt: $(wc -l < "$SEARCH_INDEX" 2>/dev/null || echo 0) lines"
}

# search_index removed (dead code — search.sh and inject.sh read $SEARCH_INDEX directly)
