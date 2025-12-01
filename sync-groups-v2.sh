#!/bin/bash
# GitHub 仓库按分组同步脚本

# ============================================
# 配置和常量定义
# ============================================
CONFIG_FILE="REPO-GROUPS.md"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================
# 日志输出函数
# ============================================

# 获取时间戳
_get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# 带时间戳的日志函数（输出到 stderr，避免被命令替换捕获）
print_info() {
    echo -e "[$(_get_timestamp)] ${BLUE}ℹ${NC} $1" >&2
}

print_warning() {
    echo -e "[$(_get_timestamp)] ${YELLOW}⚠${NC} $1" >&2
}

print_error() {
    echo -e "[$(_get_timestamp)] ${RED}✗${NC} $1" >&2
}

print_success() {
    echo -e "[$(_get_timestamp)] ${GREEN}✓${NC} $1" >&2
}

print_debug() {
    # Debug 模式已关闭
    :
}

print_step() {
    echo -e "[$(_get_timestamp)] ${BLUE}→${NC} $1" >&2
}

# 详细操作日志（带时间戳和操作类型）
print_operation_start() {
    local operation=$1
    local details=$2
    echo -e "[$(_get_timestamp)] ${BLUE}[开始]${NC} $operation ${details:+($details)}" >&2
}

print_operation_end() {
    local operation=$1
    local status=$2  # success/fail/skip/warning
    local duration=$3  # 耗时（秒）
    local details=$4
    
    case "$status" in
        "success")
            echo -e "[$(_get_timestamp)] ${GREEN}[完成]${NC} $operation ${details:+($details)} ${duration:+[耗时: ${duration}秒]}" >&2
            ;;
        "fail"|"failure")
            echo -e "[$(_get_timestamp)] ${RED}[失败]${NC} $operation ${details:+($details)} ${duration:+[耗时: ${duration}秒]}" >&2
            ;;
        "skip")
            echo -e "[$(_get_timestamp)] ${YELLOW}[跳过]${NC} $operation ${details:+($details)} ${duration:+[耗时: ${duration}秒]}" >&2
            ;;
        "warning")
            echo -e "[$(_get_timestamp)] ${YELLOW}[警告]${NC} $operation ${details:+($details)} ${duration:+[耗时: ${duration}秒]}" >&2
            ;;
        *)
            echo -e "[$(_get_timestamp)] ${BLUE}[结束]${NC} $operation ${details:+($details)} ${duration:+[耗时: ${duration}秒]}" >&2
            ;;
    esac
}

# API 调用日志
print_api_call() {
    local api_name=$1
    local params=$2
    echo -e "[$(_get_timestamp)] ${BLUE}[API调用]${NC} $api_name ${params:+($params)}" >&2
}

# 命令执行日志
print_command() {
    local cmd=$1
    echo -e "[$(_get_timestamp)] ${BLUE}[执行命令]${NC} $cmd" >&2
}

# ============================================
# 统计管理函数
# ============================================

# ============================================
# 全局缓存变量（性能优化）
# ============================================

# 仓库名称映射缓存：repo_name -> repo_full (owner/repo)
declare -gA REPO_FULL_NAME_CACHE

# 配置文件解析缓存
declare -gA GROUP_REPOS_CACHE        # group_name -> 仓库列表（多行字符串）
declare -gA GROUP_HIGHLAND_CACHE     # group_name -> 高地编号
declare -ga ALL_GROUP_NAMES_CACHE    # 所有分组名数组
declare -g CONFIG_FILE_CACHE_LOADED=0  # 配置文件是否已加载缓存

# 本地仓库缓存
declare -ga LOCAL_REPOS_CACHE        # 本地仓库完整名称列表
declare -gA LOCAL_REPOS_MAP          # repo_full -> 1 (快速查找)
declare -g LOCAL_REPOS_CACHE_LOADED=0  # 本地仓库缓存是否已加载

# 初始化全局统计变量
init_sync_stats() {
    declare -g SYNC_STATS_SUCCESS=0
    declare -g SYNC_STATS_UPDATE=0
    declare -g SYNC_STATS_FAIL=0
    declare -g CLEANUP_STATS_DELETE=0
    declare -gA group_folders
    declare -gA group_names
    
    # 初始化缓存标记
    CONFIG_FILE_CACHE_LOADED=0
    LOCAL_REPOS_CACHE_LOADED=0
}

# 更新统计信息（简化版）
update_sync_statistics() {
    local repo_path=$1
    local result=$2
    
    case $result in
        0)
            # 成功：简单判断，如果目录已存在则是更新，否则是新增
            if [ -d "$repo_path/.git" ]; then
                ((SYNC_STATS_UPDATE++))
            else
                ((SYNC_STATS_SUCCESS++))
            fi
            ;;
        2)
            # 跳过，不统计
            ;;
        *)
            # 失败
            ((SYNC_STATS_FAIL++))
            ;;
    esac
}

# 记录错误日志（统一格式）
record_error() {
    local error_log_ref=$1
    local repo=$2
    local error_type=$3
    local error_msg=$4
    
    if [ -n "$error_log_ref" ]; then
        # 使用 nameref 安全地添加元素
        local -n error_log_array=$error_log_ref
        error_log_array+=("$repo|$error_type|$error_msg")
    fi
}

# 输出最终统计信息
# 比较远程和本地差异，生成详细报告（使用缓存优化）
compare_remote_local_diff() {
    local -n failed_logs_ref=$1
    
    echo ""
    echo "=================================================="
    echo "📊 远程与本地差异分析"
    echo "=================================================="
    echo ""
    
    # 确保缓存已加载
    if [ "$LOCAL_REPOS_CACHE_LOADED" -eq 0 ]; then
        init_local_repo_cache
    fi
    
    # 获取所有应该同步的仓库列表（使用缓存）
    local expected_repos=()
    declare -A expected_repos_map=()
    
    # 从缓存中获取所有分组名称
    local groups_array=("${ALL_GROUP_NAMES_CACHE[@]}")
    
    for group_name in "${groups_array[@]}"; do
        local group_repos=$(get_group_repos "$group_name")
        if [ -z "$group_repos" ]; then
            continue
        fi
        
        local repos_array
        string_to_array repos_array "$group_repos"
        
        for repo_name in "${repos_array[@]}"; do
            if [ -z "$repo_name" ]; then
                continue
            fi
            
            # 从缓存中查找（无需 API 调用）
            local repo_full="${REPO_FULL_NAME_CACHE[$repo_name]}"
            if [ -n "$repo_full" ]; then
                expected_repos+=("$repo_full")
                expected_repos_map["$repo_full"]=1
            fi
        done
    done
    
    # 使用缓存的本地仓库列表（无需重新扫描）
    local local_repos=("${LOCAL_REPOS_CACHE[@]}")
    # 直接使用全局缓存映射（无需重新创建）
    # LOCAL_REPOS_MAP 已在 init_local_repo_cache 中建立
    
    # 分析差异
    local missing_repos=()      # 应该存在但本地缺失的
    local extra_repos=()         # 本地存在但不在同步列表中的
    local synced_repos=()        # 成功同步的
    
    # 找出缺失的仓库（应该存在但本地没有）
    # 使用全局缓存映射 LOCAL_REPOS_MAP
    for repo_full in "${expected_repos[@]}"; do
        if [ -z "${LOCAL_REPOS_MAP[$repo_full]}" ]; then
            missing_repos+=("$repo_full")
        else
            synced_repos+=("$repo_full")
        fi
    done
    
    # 找出多余的仓库（本地存在但不在同步列表中）
    for repo_full in "${local_repos[@]}"; do
        if [ -z "${expected_repos_map[$repo_full]}" ]; then
            extra_repos+=("$repo_full")
        fi
    done
    
    # 统计失败但已记录的仓库
    local failed_repos_count=0
    if [ ${#failed_logs_ref[@]} -gt 0 ]; then
        failed_repos_count=${#failed_logs_ref[@]}
    fi
    
    # 输出统计信息
    local total_expected=${#expected_repos[@]}
    local total_local=${#local_repos[@]}
    local total_synced=${#synced_repos[@]}
    local total_missing=${#missing_repos[@]}
    local total_extra=${#extra_repos[@]}
    
    print_info "📈 总体统计："
    echo "  - 应该同步的仓库总数: $total_expected"
    echo "  - 本地已存在的仓库总数: $total_local"
    echo "  - 成功同步的仓库: $total_synced"
    echo "  - 缺失的仓库（应该存在但本地没有）: $total_missing"
    echo "  - 多余的仓库（本地有但不在同步列表）: $total_extra"
    echo "  - 同步失败的仓库: $failed_repos_count"
    echo ""
    
    # 计算同步率
    if [ "$total_expected" -gt 0 ]; then
        local sync_rate=$((total_synced * 100 / total_expected))
        echo "  - 同步成功率: ${sync_rate}%"
        echo ""
    fi
    
    # 显示缺失的仓库详情
    if [ "$total_missing" -gt 0 ]; then
        print_warning "⚠️  缺失的仓库（$total_missing 个）："
        local index=1
        for repo_full in "${missing_repos[@]}"; do
            local repo_info=$(get_repo_info "$repo_full")
            local repo_desc=""
            local repo_lang=""
            local repo_stars=""
            if [ -n "$repo_info" ]; then
                repo_desc=$(extract_json_field "$repo_info" "description")
                repo_lang=$(extract_json_field "$repo_info" "language")
                repo_stars=$(extract_json_number "$repo_info" "stargazerCount")
            fi
            echo "  [$index] $repo_full"
            if [ -n "$repo_lang" ] && [ "$repo_lang" != "null" ] && [ -n "$repo_lang" ]; then
                echo "      语言: $repo_lang"
            fi
            if [ -n "$repo_stars" ] && [ "$repo_stars" != "null" ] && [ "$repo_stars" != "0" ]; then
                echo "      ⭐ Stars: $repo_stars"
            fi
            if [ -n "$repo_desc" ] && [ "$repo_desc" != "null" ] && [ -n "$repo_desc" ]; then
                # 限制描述长度
                if [ ${#repo_desc} -gt 60 ]; then
                    repo_desc="${repo_desc:0:57}..."
                fi
                echo "      描述: $repo_desc"
            fi
            ((index++))
        done
        echo ""
    fi
    
    # 显示多余的仓库详情（如果数量不多）
    if [ "$total_extra" -gt 0 ] && [ "$total_extra" -le 20 ]; then
        print_info "ℹ️  本地多余的仓库（$total_extra 个，不在同步列表中）："
        local index=1
        for repo_full in "${extra_repos[@]}"; do
            local repo_info=$(get_repo_info "$repo_full")
            local repo_desc=""
            local repo_lang=""
            local repo_stars=""
            if [ -n "$repo_info" ]; then
                repo_desc=$(extract_json_field "$repo_info" "description")
                repo_lang=$(extract_json_field "$repo_info" "language")
                repo_stars=$(extract_json_number "$repo_info" "stargazerCount")
            fi
            echo "  [$index] $repo_full"
            if [ -n "$repo_lang" ] && [ "$repo_lang" != "null" ] && [ -n "$repo_lang" ]; then
                echo "      语言: $repo_lang"
            fi
            if [ -n "$repo_stars" ] && [ "$repo_stars" != "null" ] && [ "$repo_stars" != "0" ]; then
                echo "      ⭐ Stars: $repo_stars"
            fi
            ((index++))
        done
        echo ""
    elif [ "$total_extra" -gt 20 ]; then
        print_info "ℹ️  本地多余的仓库: $total_extra 个（数量较多，已省略详情）"
        echo ""
    fi
    
    # 同步状态总结
    echo "=================================================="
    if [ "$total_missing" -eq 0 ] && [ "$failed_repos_count" -eq 0 ]; then
        print_success "✅ 所有仓库已成功同步！"
    elif [ "$total_missing" -gt 0 ] || [ "$failed_repos_count" -gt 0 ]; then
        print_warning "⚠️  同步未完全完成，存在缺失或失败的仓库"
    fi
    echo "=================================================="
}

print_final_summary() {
    echo ""
    echo "=================================================="
    echo "✅ 同步完成！"
    echo "新增: ${SYNC_STATS_SUCCESS:-0}"
    echo "更新: ${SYNC_STATS_UPDATE:-0}"
    echo "删除: ${CLEANUP_STATS_DELETE:-0}"
    echo "失败: ${SYNC_STATS_FAIL:-0}"
    echo "=================================================="
}

# 显示失败仓库详情（简化版）
print_failed_repos_details() {
    local -n failed_logs_ref=$1
    
    if [ ${#failed_logs_ref[@]} -eq 0 ]; then
        return
    fi
    
    echo ""
    echo "=================================================="
    echo "❌ 失败仓库详情："
    echo "=================================================="
    local log_index=1
    
    for failed_log in "${failed_logs_ref[@]}"; do
        IFS='|' read -r repo_identifier error_type error_msg <<< "$failed_log"
        
        # 判断是完整仓库名（owner/repo）还是仓库名
        local repo_full="$repo_identifier"
        if [[ "$repo_identifier" != *"/"* ]]; then
            repo_full="未知/$repo_identifier"
        fi
        
        echo ""
        echo "[$log_index] $repo_full"
        echo "    类型: $error_type"
        echo "    原因: $error_msg"
        ((log_index++))
    done
    
    echo ""
    echo "=================================================="
}

# ============================================
# 重试机制函数
# ============================================

# 重试单个仓库
# 参数: repo_full, repo_name, group_folder, total_count, current_index, error_log_ref
retry_repo_sync() {
    local repo_full=$1
    local repo_name=$2
    local group_folder=$3
    local total_count=$4
    local current_index=$5
    local error_log_ref=$6
    
    echo "" >&2
    print_info "[重试 $current_index/$total_count] 重试仓库: $repo_name"
    print_info "  完整仓库名: $repo_full"
    print_info "  分组文件夹: $group_folder"
    
    local retry_result
    sync_single_repo "$repo_full" "$repo_name" "$group_folder" "$current_index" "$total_count" "$error_log_ref"
    retry_result=$?
    
    if [ "$retry_result" -eq 0 ]; then
        # 注意：sync_single_repo 内部已经调用了 update_sync_statistics
        # 第一次失败时已经统计为失败，所以需要减少失败计数
        ((SYNC_STATS_FAIL--))
        print_success "  重试成功: $repo_name"
        return 0
    else
        print_error "  重试仍然失败: $repo_name"
        return 1
    fi
}

# ============================================
# 配置解析函数
# ============================================

# 列出所有分组名称（带高地编号）
list_groups() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "配置文件不存在: $CONFIG_FILE"
        return 1
    fi
    
    echo "可用分组:"
    echo ""
    
    # 获取所有分组名称
    local all_groups=$(get_all_group_names)
    local index=1
    
    # 遍历每个分组，显示分组名 + 高地编号
    while IFS= read -r group_name; do
        if [ -z "$group_name" ]; then
            continue
        fi
        
        local highland=$(get_group_highland "$group_name")
        if [ -n "$highland" ]; then
            printf "%2d. %s (%s)\n" "$index" "$group_name" "$highland"
        else
            printf "%2d. %s\n" "$index" "$group_name"
        fi
        ((index++))
    done <<< "$all_groups"
}

# 获取所有分组名称（使用缓存）
get_all_group_names() {
    # 如果缓存未加载，先加载
    if [ "$CONFIG_FILE_CACHE_LOADED" -eq 0 ]; then
        init_config_cache || return 1
    fi
    
    # 从缓存返回
    printf '%s\n' "${ALL_GROUP_NAMES_CACHE[@]}"
}

# 根据输入查找分组名称（支持部分匹配）- 使用缓存优化
find_group_name() {
    local input=$1
    
    # 确保缓存已加载
    if [ "$CONFIG_FILE_CACHE_LOADED" -eq 0 ]; then
        init_config_cache || return 1
    fi
    
    # 在一次遍历中完成精确匹配和部分匹配
    local input_lower=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    for group_name in "${ALL_GROUP_NAMES_CACHE[@]}"; do
        # 精确匹配
        if [ "$group_name" = "$input" ]; then
            echo "$group_name"
            return 0
        fi
        
        # 部分匹配（不区分大小写）
        local group_lower=$(echo "$group_name" | tr '[:upper:]' '[:lower:]')
        if [[ "$group_lower" == *"$input_lower"* ]]; then
            echo "$group_name"
            return 0
        fi
    done
    
    return 1
}

# 获取分组的高地编号（使用缓存）
get_group_highland() {
    local group_name=$1
    
    # 如果缓存未加载，先加载
    if [ "$CONFIG_FILE_CACHE_LOADED" -eq 0 ]; then
        init_config_cache || return 1
    fi
    
    # 从缓存返回
    if [ -n "${GROUP_HIGHLAND_CACHE[$group_name]}" ]; then
        echo "${GROUP_HIGHLAND_CACHE[$group_name]}"
        return 0
    fi
    
    return 1
}

# 获取分组文件夹名称（组名 + 高地编号）
get_group_folder() {
    local group_name=$1
    local highland=$(get_group_highland "$group_name")
    
    # 新的目录结构：repos/分组名 (高地编号)
    if [ -n "$highland" ]; then
        echo "repos/$group_name ($highland)"
    else
        echo "repos/$group_name"
    fi
}

# 获取分组下的所有仓库名称（使用缓存）
get_group_repos() {
    local group_name=$1
    
    # 如果缓存未加载，先加载
    if [ "$CONFIG_FILE_CACHE_LOADED" -eq 0 ]; then
        init_config_cache || return 1
    fi
    
    # 从缓存返回
    if [ -n "${GROUP_REPOS_CACHE[$group_name]}" ]; then
        echo "${GROUP_REPOS_CACHE[$group_name]}"
        return 0
    fi
    
    return 1
}

# ============================================
# 缓存初始化函数（性能优化）
# ============================================

# 初始化配置文件缓存（一次性解析配置文件）
init_config_cache() {
    if [ "$CONFIG_FILE_CACHE_LOADED" -eq 1 ]; then
        return 0  # 已加载，直接返回
    fi
    
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "配置文件不存在: $CONFIG_FILE"
        return 1
    fi
    
    print_step "解析配置文件并建立缓存..."
    local current_group=""
    local current_highland=""
    local repos_for_group=""
    
    # 清空缓存
    GROUP_REPOS_CACHE=()
    GROUP_HIGHLAND_CACHE=()
    ALL_GROUP_NAMES_CACHE=()
    
    while IFS= read -r line; do
        # 检查是否是分组标题（使用 bash 模式匹配，比 grep 快）
        if [[ "$line" =~ ^##[[:space:]] ]]; then
            # 保存上一个分组
            if [ -n "$current_group" ]; then
                GROUP_REPOS_CACHE["$current_group"]="$repos_for_group"
                if [ -n "$current_highland" ]; then
                    GROUP_HIGHLAND_CACHE["$current_group"]="$current_highland"
                fi
                ALL_GROUP_NAMES_CACHE+=("$current_group")
            fi
            
            # 解析新分组（合并 sed 操作）
            current_group=$(echo "$line" | sed -E 's/^## //;s/ <!--.*//')
            current_highland=$(echo "$line" | sed -En 's/.*<!--[[:space:]]*([^[:space:]].*[^[:space:]])[[:space:]]*-->.*/\1/p')
            
            # 处理高地编号格式（使用 bash 模式匹配）
            if [ -n "$current_highland" ] && [[ "$current_highland" =~ ^[0-9]+\.?[0-9]*高地$ ]]; then
                current_highland="${current_highland/高地/号高地}"
            fi
            
            repos_for_group=""
            continue
        fi
        
        # 如果在分组内，提取仓库名
        if [ -n "$current_group" ]; then
            # 提取仓库名（合并 sed 操作，优化字符串处理）
            local repo=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*//;s/[[:space:]]*$//')
            if [ -n "$repo" ]; then
                # 使用数组存储，最后再 join（更高效）
                if [ -z "$repos_for_group" ]; then
                    repos_for_group="$repo"
                else
                    repos_for_group="$repos_for_group"$'\n'"$repo"
                fi
            fi
        fi
    done < "$CONFIG_FILE"
    
    # 保存最后一个分组
    if [ -n "$current_group" ]; then
        GROUP_REPOS_CACHE["$current_group"]="$repos_for_group"
        if [ -n "$current_highland" ]; then
            GROUP_HIGHLAND_CACHE["$current_group"]="$current_highland"
        fi
        ALL_GROUP_NAMES_CACHE+=("$current_group")
    fi
    
    CONFIG_FILE_CACHE_LOADED=1
    print_success "配置文件缓存已建立，共 ${#ALL_GROUP_NAMES_CACHE[@]} 个分组"
}

# 初始化仓库名称缓存（批量获取所有仓库）
init_repo_cache() {
    print_step "批量获取所有远程仓库并建立缓存..."
    
    local all_repos=$(gh repo list --limit 1000 --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        print_error "无法获取仓库列表。请确保已登录 GitHub CLI (运行: gh auth login)"
        return 1
    fi
    
    # 清空缓存
    REPO_FULL_NAME_CACHE=()
    
    # 建立映射：repo_name -> repo_full
    while IFS= read -r repo_full; do
        if [ -z "$repo_full" ]; then
            continue
        fi
        local repo_name=$(basename "$repo_full")
        REPO_FULL_NAME_CACHE["$repo_name"]="$repo_full"
    done <<< "$all_repos"
    
    local repo_count=${#REPO_FULL_NAME_CACHE[@]}
    print_success "已缓存 $repo_count 个远程仓库"
}

# 初始化本地仓库缓存（扫描本地所有仓库）
init_local_repo_cache() {
    if [ "$LOCAL_REPOS_CACHE_LOADED" -eq 1 ]; then
        return 0  # 已加载，直接返回
    fi
    
    print_step "扫描本地仓库并建立缓存..."
    
    # 清空缓存
    LOCAL_REPOS_CACHE=()
    LOCAL_REPOS_MAP=()
    
    # 遍历所有分组文件夹
    for group_folder in "${!group_folders[@]}"; do
        if [ ! -d "$group_folder" ]; then
            continue
        fi
        
        shopt -s nullglob
        for dir in "$group_folder"/*; do
            if [ -d "$dir" ] && [ -d "$dir/.git" ]; then
                local repo_name=$(basename "$dir")
                # 从缓存中查找完整名称
                if [ -n "${REPO_FULL_NAME_CACHE[$repo_name]}" ]; then
                    local repo_full="${REPO_FULL_NAME_CACHE[$repo_name]}"
                    LOCAL_REPOS_CACHE+=("$repo_full")
                    LOCAL_REPOS_MAP["$repo_full"]=1
                fi
            fi
        done
        shopt -u nullglob
    done
    
    LOCAL_REPOS_CACHE_LOADED=1
    print_success "本地仓库缓存已建立，共 ${#LOCAL_REPOS_CACHE[@]} 个仓库"
}

# ============================================
# GitHub API 操作函数
# ============================================

# 缓存 GitHub 用户名（避免重复调用 API）
_GITHUB_USER_CACHE=""

# 获取 GitHub 用户名（带缓存）
get_github_username() {
    if [ -z "$_GITHUB_USER_CACHE" ]; then
        _GITHUB_USER_CACHE=$(gh api user --jq '.login' 2>/dev/null || echo "")
    fi
    echo "$_GITHUB_USER_CACHE"
}

# 初始化 GitHub 连接
init_github_connection() {
    # 添加 GitHub 主机密钥（如果需要）
    if [ ! -f ~/.ssh/known_hosts ] || ! grep -q "github.com" ~/.ssh/known_hosts 2>/dev/null; then
        mkdir -p ~/.ssh
        ssh-keyscan -t rsa,ecdsa,ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null || true
    fi
    
    # 配置 Git 加速选项
    git config --global http.postBuffer 524288000 2>/dev/null || true
    git config --global http.lowSpeedLimit 0 2>/dev/null || true
    git config --global http.lowSpeedTime 0 2>/dev/null || true
    git config --global core.preloadindex true 2>/dev/null || true
    git config --global core.fscache true 2>/dev/null || true
}

# 获取所有远程仓库列表
fetch_remote_repos() {
    print_step "通过 GitHub CLI 获取仓库列表..."
    local all_repos=$(gh repo list --limit 1000 --json nameWithOwner --jq '.[].nameWithOwner')
    
    if [ $? -ne 0 ]; then
        print_error "无法获取仓库列表。请确保已登录 GitHub CLI (运行: gh auth login)"
        exit 1
    fi
    
    local repo_count=$(echo "$all_repos" | wc -l | tr -d ' ')
    print_success "成功获取 $repo_count 个远程仓库"
    print_debug "远程仓库列表: $(echo "$all_repos" | head -5 | tr '\n' ', ')..."
    
    echo "$all_repos"
}

# 查找仓库的完整名称（owner/repo）- 使用缓存优化
find_repo_full_name() {
    local repo_name=$1
    
    # 先查缓存
    if [ -n "${REPO_FULL_NAME_CACHE[$repo_name]}" ]; then
        echo "${REPO_FULL_NAME_CACHE[$repo_name]}"
        return 0
    fi
    
    # 缓存未命中，尝试通过 API 查找（应该很少发生）
    local repo_owner=$(get_github_username)
    
    if [ -z "$repo_owner" ]; then
        return 1
    fi
    
    local repo_full="$repo_owner/$repo_name"
    if gh repo view "$repo_full" &>/dev/null; then
        # 缓存结果
        REPO_FULL_NAME_CACHE["$repo_name"]="$repo_full"
        echo "$repo_full"
        return 0
    else
        return 1
    fi
}

# ============================================
# 仓库操作函数：同步和清理
# ============================================

# 获取仓库详细信息（返回 JSON 字符串）
get_repo_info() {
    local repo_full=$1
    # 使用 gh repo view 获取仓库信息，失败时返回空
    gh repo view "$repo_full" --json \
        name,description,language,stargazerCount,forkCount,updatedAt,isArchived,isPrivate 2>/dev/null || echo ""
}

# 从 JSON 中提取字段值（优化版，直接解析 JSON）
extract_json_field() {
    local json=$1
    local field=$2
    
    # 优先使用 jq（如果可用）
    if command -v jq >/dev/null 2>&1; then
        echo "$json" | jq -r ".$field // empty" 2>/dev/null && return 0
    fi
    
    # 回退到简单的字符串匹配（提取字符串值）
    local value=$(echo "$json" | grep -o "\"$field\":\"[^\"]*\"" | sed "s/\"$field\":\"\([^\"]*\)\"/\1/" 2>/dev/null)
    if [ -n "$value" ]; then
        echo "$value"
        return 0
    fi
    
    # 尝试提取 null 或其他值
    echo "$json" | grep -o "\"$field\":null" >/dev/null 2>&1 && echo "" && return 0
    
    echo ""
}

# 从 JSON 中提取数字字段值（使用简单的字符串处理）
extract_json_number() {
    local json=$1
    local field=$2
    # 提取数字字段（支持 null 值）
    local value=$(echo "$json" | grep -o "\"$field\":[0-9]*" | sed "s/\"$field\":\([0-9]*\)/\1/" 2>/dev/null)
    if [ -z "$value" ]; then
        echo "0"
    else
        echo "$value"
    fi
}

# 克隆仓库
clone_repo() {
    local repo=$1
    local repo_path=$2
    local current_index=$3
    local total_sync=$4
    local error_log_ref=${5:-""}
    
    # 切换到脚本目录，确保相对路径正确
    cd "$SCRIPT_DIR" || {
        print_error "  错误: 无法切换到脚本目录: $SCRIPT_DIR"
        return 1
    }
    
    echo "[$current_index/$total_sync] [克隆] $repo -> $(dirname "$repo_path")/..." >&2
    print_info "  正在克隆仓库: $repo"
    print_info "  目标路径: $repo_path"
    
    # 创建父目录（分组文件夹），确保目录存在
    local parent_dir=$(dirname "$repo_path")
    if [ ! -d "$parent_dir" ]; then
        mkdir -p "$parent_dir"
        print_info "  已创建分组文件夹: $parent_dir"
    fi
    
    # 获取仓库信息（用于显示）
    local repo_info=$(get_repo_info "$repo")
    if [ -n "$repo_info" ]; then
        local repo_desc=$(extract_json_field "$repo_info" "description")
        local repo_lang=$(extract_json_field "$repo_info" "language")
        local repo_stars=$(extract_json_number "$repo_info" "stargazerCount")
        if [ -n "$repo_desc" ] && [ "$repo_desc" != "null" ]; then
            print_info "  描述: $repo_desc"
        fi
        if [ -n "$repo_lang" ] && [ "$repo_lang" != "null" ] && [ "$repo_lang" != "未知" ]; then
            print_info "  语言: $repo_lang"
        fi
        if [ -n "$repo_stars" ] && [ "$repo_stars" != "null" ] && [ "$repo_stars" != "0" ]; then
            print_info "  ⭐ Stars: $repo_stars"
        fi
    fi
    
    # 使用 gh repo clone（自动处理协议选择，更好的错误处理）
    local clone_start_time=$(date +%s)
    gh repo clone "$repo" "$repo_path" -- --quiet 2>&1
    local clone_exit_code=$?
    local clone_end_time=$(date +%s)
    local clone_duration=$((clone_end_time - clone_start_time))
    
    # 如果失败，获取错误信息
    local clone_output=""
    if [ "$clone_exit_code" -ne 0 ]; then
        clone_output="克隆失败，退出代码: $clone_exit_code"
    fi
    
    if [ "$clone_exit_code" -eq 0 ]; then
        echo "✓ 成功（耗时 ${clone_duration}秒）" >&2
        print_success "  克隆成功: $repo_path"
        return 0
    else
        echo "✗ 失败（耗时 ${clone_duration}秒）" >&2
        local error_msg="${clone_output:-克隆失败，退出代码: $clone_exit_code}"
        print_error "  克隆失败: $error_msg"
        print_error "  请查看上方的错误信息"
        record_error "$error_log_ref" "$repo" "克隆失败" "$error_msg"
        return 1
    fi
}

# 准备仓库更新环境（检查分支、处理冲突）
prepare_repo_for_update() {
    # 检查并处理分支状态
    local current_branch=$(git symbolic-ref -q HEAD 2>/dev/null || echo "")
    if [ -z "$current_branch" ]; then
        # detached HEAD，尝试切换到默认分支
        local default_branch=$(git remote show origin 2>/dev/null | grep "HEAD branch" | sed 's/.*: //' || echo "main")
        git checkout -b "$default_branch" >/dev/null 2>&1 || git checkout "$default_branch" >/dev/null 2>&1
    fi
    
    # 获取当前分支名
    local branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    
    # 处理未提交的更改和冲突状态
    local uncommitted_changes=$(git status --porcelain 2>/dev/null | wc -l)
    if [ "$uncommitted_changes" -gt 0 ]; then
        git stash >/dev/null 2>&1
    fi
    
    # 清理未完成的合并/变基
    [ -f ".git/MERGE_HEAD" ] && git merge --abort >/dev/null 2>&1
    [ -f ".git/CHERRY_PICK_HEAD" ] && git cherry-pick --abort >/dev/null 2>&1
    [ -f ".git/REBASE_HEAD" ] && git rebase --abort >/dev/null 2>&1
    
    echo "$branch|$uncommitted_changes"
}

# 执行仓库同步操作（优先使用 gh repo sync，回退到 git pull）
execute_repo_sync() {
    local repo_full=$1
    local repo_path=$2
    local branch=$3
    local sync_exit_code=1
    
    # 检查是否是 fork 仓库（有 upstream remote）
    local has_upstream=$(cd "$repo_path" && git remote get-url upstream 2>/dev/null || echo "")
    
    if [ -n "$has_upstream" ]; then
        # 如果是 fork 仓库，使用 gh repo sync（同步到上游）
        print_info "    检测到 fork 仓库，使用 gh repo sync 同步到上游..."
        cd "$repo_path" && gh repo sync --branch "$branch" >&2 2>&1
        sync_exit_code=$?
    fi
    
    # 如果不是 fork 或 sync 失败，使用 git pull
    if [ "$sync_exit_code" -ne 0 ] || [ -z "$has_upstream" ]; then
        # 尝试拉取（输出重定向到 stderr，避免被 $() 捕获）
        cd "$repo_path" && git pull --no-edit --rebase origin "$branch" >&2
        sync_exit_code=$?
        
        # 如果失败，尝试普通 pull
        if [ "$sync_exit_code" -ne 0 ]; then
            [ -f "$repo_path/.git/REBASE_HEAD" ] && cd "$repo_path" && git rebase --abort >/dev/null 2>&1
            cd "$repo_path" && git pull --no-edit origin "$branch" >&2
            sync_exit_code=$?
        fi
        
        # 如果还是失败，尝试直接拉取
        if [ "$sync_exit_code" -ne 0 ]; then
            [ -f "$repo_path/.git/MERGE_HEAD" ] && cd "$repo_path" && git merge --abort >/dev/null 2>&1
            cd "$repo_path" && git pull --no-edit >&2
            sync_exit_code=$?
        fi
    fi
    
    echo "$sync_exit_code"
}

# 更新已有仓库
update_repo() {
    local repo=$1
    local repo_path=$2
    local group_folder=$3
    local current_index=$4
    local total_sync=$5
    local error_log_ref=${6:-""}
    
    # 切换到脚本目录，确保相对路径正确
    cd "$SCRIPT_DIR" || {
        print_error "  错误: 无法切换到脚本目录: $SCRIPT_DIR"
        return 1
    }
    
    echo -n "[$current_index/$total_sync] [更新] $repo ($group_folder)... " >&2
    print_info "  正在更新仓库: $repo"
    print_info "  仓库路径: $repo_path"
    
    # 保存当前目录
    local original_dir=$(pwd)
    
    cd "$repo_path" || {
        local error_msg="无法进入仓库目录: $repo_path"
        print_error "  错误: $error_msg"
        record_error "$error_log_ref" "$repo" "更新失败" "$error_msg"
        return 1
    }
    
    # 准备更新环境
    local prep_result=$(prepare_repo_for_update)
    IFS='|' read -r branch uncommitted_changes <<< "$prep_result"
    
    # 获取拉取前的提交哈希
    local before_hash=$(git rev-parse HEAD 2>/dev/null || echo "")
    local pull_start_time=$(date +%s)
    
    # 获取仓库信息（用于显示）
    local repo_info=$(get_repo_info "$repo")
    if [ -n "$repo_info" ]; then
        local repo_desc=$(extract_json_field "$repo_info" "description")
        local repo_lang=$(extract_json_field "$repo_info" "language")
        local repo_stars=$(extract_json_number "$repo_info" "stargazerCount")
        if [ -n "$repo_desc" ] && [ "$repo_desc" != "null" ]; then
            print_info "  描述: $repo_desc"
        fi
        if [ -n "$repo_lang" ] && [ "$repo_lang" != "null" ] && [ "$repo_lang" != "未知" ]; then
            print_info "  语言: $repo_lang"
        fi
        if [ -n "$repo_stars" ] && [ "$repo_stars" != "null" ] && [ "$repo_stars" != "0" ]; then
            print_info "  ⭐ Stars: $repo_stars"
        fi
    fi
    
    # 执行同步（优先使用 gh repo sync，回退到 git pull）
    local pull_exit_code=$(execute_repo_sync "$repo" "$repo_path" "$branch")
    
    local pull_end_time=$(date +%s)
    local pull_duration=$((pull_end_time - pull_start_time))
    
    # 如果失败，获取错误信息
    local pull_output=""
    if [ "$pull_exit_code" -ne 0 ]; then
        pull_output="拉取失败，退出代码: $pull_exit_code"
    fi
    
    # 恢复暂存的更改（如果有）
    if [ "$uncommitted_changes" -gt 0 ] || [ -n "$(git stash list 2>/dev/null | head -n 1)" ]; then
        git stash pop >/dev/null 2>&1
    fi
    
    if [ "$pull_exit_code" -eq 0 ]; then
        local after_hash=$(git rev-parse HEAD 2>/dev/null || echo "")
        if [ "$before_hash" != "$after_hash" ] && [ -n "$before_hash" ] && [ -n "$after_hash" ]; then
            print_info "    仓库已更新（${before_hash:0:8} -> ${after_hash:0:8}）"
        fi
        echo "✓ 成功（耗时 ${pull_duration}秒）" >&2
        cd "$original_dir" || true
        return 0
    else
        echo "✗ 失败（耗时 ${pull_duration}秒）" >&2
        # 错误信息已经在终端显示了，这里只记录基本错误
        local error_msg="${pull_output:-拉取失败，退出代码: $pull_exit_code}"
        print_error "  拉取失败: $error_msg"
        print_error "  请查看上方的错误信息"
        print_error "  可能原因: 网络问题、权限问题、或需要手动解决的冲突"
        # 记录失败日志
        record_error "$error_log_ref" "$repo" "更新失败" "$error_msg"
        cd "$original_dir" || true
        return 1
    fi
}

# 同步单个仓库（克隆或更新）
sync_single_repo() {
    local repo=$1
    local repo_name=$2
    local group_folder=$3
    local current_index=$4
    local total_sync=$5
    local error_log_ref=${6:-""}
    
    # 创建分组文件夹
    if [ ! -d "$group_folder" ]; then
        mkdir -p "$group_folder"
    fi
    
    local repo_path="$group_folder/$repo_name"
    
    # 检查是否已存在
    if [ -d "$repo_path/.git" ]; then
        # 已存在 git 仓库，执行更新
        update_repo "$repo" "$repo_path" "$group_folder" "$current_index" "$total_sync" "$error_log_ref"
        return $?
    elif [ -d "$repo_path" ]; then
        # 目录存在但不是 git 仓库，跳过
        echo "[$current_index/$total_sync] [跳过] $repo - 目录已存在但不是 git 仓库" >&2
        record_error "$error_log_ref" "$repo" "跳过" "目录已存在但不是 git 仓库"
        return 2
    else
        # 新仓库，执行克隆
        clone_repo "$repo" "$repo_path" "$current_index" "$total_sync" "$error_log_ref"
        return $?
    fi
}

# 清理远程已删除的本地仓库
cleanup_deleted_repos() {
    local -n group_folders_ref=$1
    local -n sync_repos_map_ref=$2
    
    print_step "检查需要删除的本地仓库（远程已不存在）..."
    local delete_count=0
    
    # 获取仓库所有者（用于检查远程仓库是否存在）
    local repo_owner=$(get_github_username)
    if [ -n "$repo_owner" ]; then
        print_info "仓库所有者: $repo_owner"
    else
        print_warning "无法获取仓库所有者信息，将跳过远程仓库存在性检查"
    fi
    
    # 遍历所有分组文件夹
    local check_dirs=()
    for group_folder in "${!group_folders_ref[@]}"; do
        if [ -d "$group_folder" ]; then
            print_debug "检查分组文件夹: $group_folder"
            # 使用 nullglob 处理空目录情况
            shopt -s nullglob
            for dir in "$group_folder"/*; do
                [ -d "$dir" ] && check_dirs+=("$dir")
            done
            shopt -u nullglob
        fi
    done
    
    print_info "找到 ${#check_dirs[@]} 个本地目录需要检查"
    
    if [ ${#check_dirs[@]} -eq 0 ]; then
        print_info "没有需要检查的本地目录"
        CLEANUP_STATS_DELETE=0
        return 0
    fi
    
    echo ""
    # 遍历目录
    for local_dir in "${check_dirs[@]}"; do
        # 规范化路径（去除尾部斜杠）
        local normalized_dir="${local_dir%/}"
        
        # 跳过非目录或非 git 仓库
        [ ! -d "$normalized_dir" ] && continue
        [ ! -d "$normalized_dir/.git" ] && continue
        
        local repo_name=$(basename "$normalized_dir")
        local repo_path="$normalized_dir"
        
        print_debug "检查本地仓库: $repo_path"
        
        # 检查是否在要同步的仓库列表中
        if [ -z "${sync_repos_map_ref[$repo_path]}" ]; then
            # 如果不在要同步的分组中，检查是否在远程还存在
            # 使用缓存检查，避免 API 调用
            local repo_full="${REPO_FULL_NAME_CACHE[$repo_name]}"
            if [ -n "$repo_full" ]; then
                # 仓库在缓存中存在，说明远程还存在，只是不在当前同步的分组中
                print_info "  仓库 $repo_name 还在远程，只是不在当前同步的分组中，保留"
                continue
            else
                # 不在缓存中，说明远程可能不存在（但可能不在前1000个仓库中，保守处理）
                print_warning "  仓库 $repo_name 不在仓库列表中（可能已删除或不在前1000个仓库）"
                # 如果需要精确检查，可以使用 API（但会慢一些）
                if [ -n "$repo_owner" ]; then
                    print_info "  检查远程仓库是否存在: $repo_owner/$repo_name"
                    if gh repo view "$repo_owner/$repo_name" &>/dev/null; then
                        print_info "  仓库 $repo_name 还在远程，只是不在当前同步的分组中，保留"
                        continue
                    else
                        print_warning "  仓库 $repo_name 在远程已不存在"
                    fi
                fi
            fi
            
            # 仓库已不存在，删除
            echo -n "[删除] $repo_path (远程仓库已不存在)... "
            print_info "  正在删除: $repo_path"
            local rm_output=$(rm -rf "$repo_path" 2>&1)
            local rm_exit=$?
            
            if [ "$rm_exit" -eq 0 ]; then
                echo "✓ 已删除"
                ((delete_count++))
                print_success "  已成功删除: $repo_path"
            else
                echo "✗ 删除失败"
                print_error "  删除失败: $repo_path"
                if [ -n "$rm_output" ]; then
                    print_error "  错误信息: $rm_output"
                fi
            fi
        else
            print_info "  仓库 $repo_name 在同步列表中，保留"
        fi
    done
    
    if [ "$delete_count" -eq 0 ]; then
        print_info "没有需要删除的本地仓库。"
    else
        echo ""
        print_info "已删除 $delete_count 个本地仓库（远程已不存在）。"
    fi
    
    CLEANUP_STATS_DELETE=$delete_count
}

# ============================================
# 工作流程辅助函数
# ============================================

# 将多行字符串转换为数组
string_to_array() {
    local -n arr_ref=$1
    local input=$2
    arr_ref=()
    while IFS= read -r line; do
        [ -n "$line" ] && arr_ref+=("$line")
    done <<< "$input"
}

# 将数组输出为多行字符串
array_to_string() {
    local arr=("$@")
    printf '%s\n' "${arr[@]}"
}

# 获取所有分组用于同步
get_all_groups_for_sync() {
    local all_groups=$(get_all_group_names)
    if [ -z "$all_groups" ]; then
        print_error "无法读取分组列表"
        return 1
    fi
    
    local groups_array
    string_to_array groups_array "$all_groups"
    
    if [ ${#groups_array[@]} -eq 0 ]; then
        print_error "配置文件中没有找到任何分组"
        return 1
    fi
    
    array_to_string "${groups_array[@]}"
    return 0
}

# 初始化同步环境
initialize_sync() {
    # 检查配置文件
    print_step "检查配置文件..."
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "分类文档不存在: $CONFIG_FILE"
        print_info "请参考 REPO-GROUPS.md.example 创建分类文档"
        print_info "或使用 PROMPT.md 中的 prompt 让 AI 生成"
        exit 1
    fi
    print_success "配置文件存在: $CONFIG_FILE"
    
    # 创建 repos 目录（如果不存在）
    if [ ! -d "repos" ]; then
        mkdir -p "repos"
        print_info "已创建 repos 目录"
    fi
    
    # 初始化 GitHub 连接
    init_github_connection
    
    # 显示同步信息
    echo "=================================================="
    echo "GitHub 仓库分组同步工具"
    echo "=================================================="
    echo ""
    
    # 初始化统计变量
    init_sync_stats
}

# 构建同步仓库映射（用于清理检查）- 使用缓存优化
build_sync_repos_map() {
    local -n sync_repos_map_ref=$1
    
    # 从配置文件中的期望同步仓库列表构建映射（无需遍历文件系统）
    # 遍历所有分组和仓库，构建期望的路径映射
    local groups_array=("${ALL_GROUP_NAMES_CACHE[@]}")
    
    for group_name in "${groups_array[@]}"; do
        local group_folder=$(get_group_folder "$group_name")
        local group_repos=$(get_group_repos "$group_name")
        
        if [ -z "$group_repos" ]; then
            continue
        fi
        
        local repos_array
        string_to_array repos_array "$group_repos"
        
        for repo_name in "${repos_array[@]}"; do
            if [ -z "$repo_name" ]; then
                continue
            fi
            
            local repo_path="$group_folder/$repo_name"
            sync_repos_map_ref["$repo_path"]=1
        done
    done
}

# 同步单个分组的所有仓库
sync_group_repos_main() {
    local group_name=$1
    local group_folder=$2
    local group_repos=$3
    local error_log_ref=$4
    
    # 注册分组文件夹映射（用于清理）
    group_folders["$group_folder"]=1
    group_names["$group_folder"]="$group_name"
    
    # 将仓库列表转换为数组，便于计算总数和遍历
    local repos_array
    string_to_array repos_array "$group_repos"
    
    local total_count=${#repos_array[@]}
    
    # 记录失败的仓库（用于最后统一重试）
    local failed_repos=()
    
    print_step "开始同步分组 '$group_name'（共 $total_count 个仓库）..."
    print_info "分组文件夹: $group_folder"
    echo "" >&2
    
    # 创建分组文件夹（如果不存在）
    if [ ! -d "$group_folder" ]; then
        mkdir -p "$group_folder"
    fi
    
    # 第一步：分类仓库 - 区分需要克隆的（缺失）和需要更新的（已存在）
    local repos_to_clone=()  # 需要克隆的仓库（缺失的）
    local repos_to_update=() # 需要更新的仓库（已存在的）
    
    print_info "检查仓库状态，分类处理..."
    for repo_name in "${repos_array[@]}"; do
        if [ -z "$repo_name" ]; then
            continue
        fi
        
        # 查找仓库完整名称
        local repo_full=$(find_repo_full_name "$repo_name")
        
        if [ -z "$repo_full" ]; then
            echo "[错误] $repo_name - 远程仓库不存在" >&2
            record_error "$error_log_ref" "$repo_name" "错误" "远程仓库不存在"
            update_sync_statistics "" 1
            continue
        fi
        
        local repo_path="$group_folder/$repo_name"
        
        # 检查仓库是否存在
        if [ -d "$repo_path/.git" ]; then
            # 已存在 git 仓库，加入更新列表
            repos_to_update+=("$repo_full|$repo_name")
        elif [ -d "$repo_path" ]; then
            # 目录存在但不是 git 仓库，跳过
            echo "[跳过] $repo_name - 目录已存在但不是 git 仓库" >&2
            record_error "$error_log_ref" "$repo_name" "跳过" "目录已存在但不是 git 仓库"
            update_sync_statistics "$repo_path" 2
        else
            # 新仓库，加入克隆列表
            repos_to_clone+=("$repo_full|$repo_name")
        fi
    done
    
    local clone_count=${#repos_to_clone[@]}
    local update_count=${#repos_to_update[@]}
    
    echo "" >&2
    print_info "仓库分类完成："
    print_info "  - 需要克隆（缺失）: $clone_count 个"
    print_info "  - 需要更新（已存在）: $update_count 个"
    echo "" >&2
    
    # 第二步：优先处理需要克隆的仓库（缺失的）
    if [ "$clone_count" -gt 0 ]; then
        print_step "优先同步缺失的仓库（$clone_count 个）..."
        echo "" >&2
        
        local current_index=0
        for repo_info in "${repos_to_clone[@]}"; do
            IFS='|' read -r repo_full repo_name <<< "$repo_info"
            ((current_index++))
            
            echo "" >&2
            print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            print_info "处理仓库 [$current_index/$clone_count]: $repo_name [克隆]"
            print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            
            # 执行克隆
            local repo_path="$group_folder/$repo_name"
            local result
            clone_repo "$repo_full" "$repo_path" "$current_index" "$clone_count" "$error_log_ref"
            result=$?
            
            # 更新统计信息
            update_sync_statistics "$repo_path" "$result"
            
            # 记录失败的仓库（用于重试）
            if [ "$result" -ne 0 ]; then
                failed_repos+=("$repo_full|$repo_name")
            fi
        done
        
        echo "" >&2
        if [ "$clone_count" -gt 0 ]; then
            print_success "缺失仓库同步完成（$clone_count 个）"
            echo "" >&2
        fi
    fi
    
    # 第三步：处理需要更新的仓库（已存在的）
    if [ "$update_count" -gt 0 ]; then
        print_step "更新已存在的仓库（$update_count 个）..."
        echo "" >&2
        
        local current_index=0
        for repo_info in "${repos_to_update[@]}"; do
            IFS='|' read -r repo_full repo_name <<< "$repo_info"
            ((current_index++))
            
            echo "" >&2
            print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            print_info "处理仓库 [$current_index/$update_count]: $repo_name [更新]"
            print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            
            # 执行更新
            local repo_path="$group_folder/$repo_name"
            local result
            update_repo "$repo_full" "$repo_path" "$group_folder" "$current_index" "$update_count" "$error_log_ref"
            result=$?
            
            # 更新统计信息
            update_sync_statistics "$repo_path" "$result"
            
            # 记录失败的仓库（用于重试）
            if [ "$result" -ne 0 ] && [ "$result" -ne 2 ]; then
                failed_repos+=("$repo_full|$repo_name")
            fi
        done
        
        echo "" >&2
        if [ "$update_count" -gt 0 ]; then
            print_success "已存在仓库更新完成（$update_count 个）"
            echo "" >&2
        fi
    fi
    
    # 返回失败的仓库列表（用于最后统一重试）
    array_to_string "${failed_repos[@]}"
}

# 同步分组中的仓库（主入口）
sync_group_repos() {
    local group_name=$1
    local group_folder=$2
    local group_repos=$3
    local global_failed_array=${4:-""}
    local error_log_ref=${5:-""}
    
    # 同步分组的所有仓库
    local failed_repos_output=$(sync_group_repos_main "$group_name" "$group_folder" "$group_repos" "$error_log_ref")
    
    # 将输出转换为数组
    local failed_repos
    string_to_array failed_repos "$failed_repos_output"
    
    # 将失败的仓库添加到全局数组（用于最后统一重试）
    if [ ${#failed_repos[@]} -gt 0 ] && [ -n "$global_failed_array" ]; then
        local -n global_array_ref=$global_failed_array
        for failed_repo in "${failed_repos[@]}"; do
            IFS='|' read -r repo_full repo_name <<< "$failed_repo"
            global_array_ref+=("$repo_full|$repo_name|$group_folder")
        done
    fi
    
    if [ ${#failed_repos[@]} -gt 0 ]; then
        print_warning "分组 '$group_name' 同步完成，有 ${#failed_repos[@]} 个仓库失败，将在最后统一重试"
    else
        print_success "分组 '$group_name' 同步完成，所有仓库同步成功！"
    fi
}

# 全局扫描差异：找出所有缺失和需要更新的仓库
scan_global_diff() {
    local groups=("$@")
    
    # 存储全局的缺失和更新仓库列表（按分组组织）
    declare -gA global_repos_to_clone  # key: group_folder, value: "repo_full|repo_name repo_full|repo_name ..."
    declare -gA global_repos_to_update   # key: group_folder, value: "repo_full|repo_name repo_full|repo_name ..."
    
    print_step "全局扫描差异，分析所有仓库状态..."
    echo ""
    
    local total_expected=0
    local total_missing=0
    local total_to_update=0
    local total_skipped=0
    local total_not_found=0
    
    # 计算总仓库数（用于显示进度）
    local total_repos=0
    for input_group in "${groups[@]}"; do
        local group_name=$(find_group_name "$input_group")
        if [ -z "$group_name" ]; then
            continue
        fi
        local group_repos=$(get_group_repos "$group_name")
        if [ -z "$group_repos" ]; then
            continue
        fi
        local repos_array
        string_to_array repos_array "$group_repos"
        total_repos=$((total_repos + ${#repos_array[@]}))
    done
    
    print_info "📋 共需要检查 $total_repos 个仓库，开始扫描..."
    echo ""
    
    local current_repo_index=0
    local group_index=0
    
    # 遍历所有分组，收集缺失和更新的仓库
    for input_group in "${groups[@]}"; do
        local group_name=$(find_group_name "$input_group")
        
        if [ -z "$group_name" ]; then
            continue
        fi
        
        ((group_index++))
        local group_folder=$(get_group_folder "$group_name")
        local group_repos=$(get_group_repos "$group_name")
        
        if [ -z "$group_repos" ]; then
            continue
        fi
        
        # 创建分组文件夹（如果不存在）
        if [ ! -d "$group_folder" ]; then
            mkdir -p "$group_folder"
        fi
        
        # 注册分组文件夹映射
        group_folders["$group_folder"]=1
        group_names["$group_folder"]="$group_name"
        
        local repos_array
        string_to_array repos_array "$group_repos"
        
        local group_missing=()
        local group_to_update=()
        
        print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        print_info "检查分组 [$group_index/${#groups[@]}]: $group_name (${#repos_array[@]} 个仓库)"
        print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # 检查每个仓库的状态
        local repo_in_group_index=0
        for repo_name in "${repos_array[@]}"; do
            if [ -z "$repo_name" ]; then
                continue
            fi
            
            ((current_repo_index++))
            ((repo_in_group_index++))
            ((total_expected++))
            
            # 显示检查进度
            echo -n "  [$current_repo_index/$total_repos] 检查: $repo_name ... " >&2
            
            # 查找仓库完整名称
            local repo_full=$(find_repo_full_name "$repo_name")
            
            if [ -z "$repo_full" ]; then
                echo "❌ 远程不存在" >&2
                ((total_not_found++))
                continue
            fi
            
            local repo_path="$group_folder/$repo_name"
            local old_repo_path="$repo_name"  # 检查根目录下的旧位置
            
            # 检查仓库是否存在（优先检查新位置，再检查旧位置）
            if [ -d "$repo_path/.git" ]; then
                # 已存在 git 仓库（新位置），加入更新列表
                group_to_update+=("$repo_full|$repo_name")
                ((total_to_update++))
                echo "✅ 已存在 (需更新)" >&2
            elif [ -d "$old_repo_path/.git" ]; then
                # 仓库在旧位置（根目录），需要移动到新位置
                print_info "  检测到仓库在旧位置: $old_repo_path，将移动到新位置: $repo_path"
                # 创建新位置的分组文件夹
                local parent_dir=$(dirname "$repo_path")
                if [ ! -d "$parent_dir" ]; then
                    mkdir -p "$parent_dir"
                fi
                # 移动仓库到新位置
                if mv "$old_repo_path" "$repo_path" 2>/dev/null; then
                    group_to_update+=("$repo_full|$repo_name")
                    ((total_to_update++))
                    echo "✅ 已移动并加入更新列表" >&2
                else
                    # 移动失败，仍然加入更新列表（尝试在新位置更新）
                    echo "⚠️  移动失败，但仍将尝试更新" >&2
                    group_to_update+=("$repo_full|$repo_name")
                    ((total_to_update++))
                fi
            elif [ -d "$repo_path" ]; then
                # 目录存在但不是 git 仓库，跳过
                echo "⚠️  目录存在但非 git 仓库 (跳过)" >&2
                ((total_skipped++))
                continue
            else
                # 新仓库，加入缺失列表
                group_missing+=("$repo_full|$repo_name")
                ((total_missing++))
                echo "🔴 缺失 (需克隆)" >&2
            fi
        done
        
        # 显示分组统计
        echo "" >&2
        if [ ${#group_missing[@]} -gt 0 ] || [ ${#group_to_update[@]} -gt 0 ]; then
            print_info "  分组 '$group_name' 统计："
            if [ ${#group_missing[@]} -gt 0 ]; then
                print_warning "    - 缺失: ${#group_missing[@]} 个"
            fi
            if [ ${#group_to_update[@]} -gt 0 ]; then
                print_info "    - 已存在: ${#group_to_update[@]} 个"
            fi
        fi
        echo "" >&2
        
        # 存储到全局数组
        if [ ${#group_missing[@]} -gt 0 ]; then
            global_repos_to_clone["$group_folder"]=$(printf '%s\n' "${group_missing[@]}")
        fi
        
        if [ ${#group_to_update[@]} -gt 0 ]; then
            global_repos_to_update["$group_folder"]=$(printf '%s\n' "${group_to_update[@]}")
        fi
    done
    
    echo ""
    echo "=================================================="
    print_info "📊 全局差异分析完成"
    echo "=================================================="
    echo ""
    print_info "总体统计："
    echo "  - 检查的仓库总数: $total_expected"
    echo "  - 🔴 缺失的仓库（需要克隆）: $total_missing 个"
    echo "  - ✅ 需要更新的仓库（已存在）: $total_to_update 个"
    if [ "$total_skipped" -gt 0 ]; then
        echo "  - ⚠️  跳过的仓库（非 git 仓库）: $total_skipped 个"
    fi
    if [ "$total_not_found" -gt 0 ]; then
        echo "  - ❌ 远程不存在的仓库: $total_not_found 个"
    fi
    echo ""
    
    if [ "$total_missing" -gt 0 ]; then
        print_warning "⚠️  发现 $total_missing 个缺失的仓库，将优先同步（优先级最高）"
        print_info "   执行顺序：先同步所有缺失的仓库 → 再更新所有已存在的仓库"
    elif [ "$total_to_update" -gt 0 ]; then
        print_info "✅ 所有仓库已存在，将执行更新操作"
    fi
    echo ""
}

# 执行同步操作（遍历所有分组）- 支持并行处理
execute_sync() {
    local groups=("$@")
    
    # 并行处理的并发数（默认 5，可通过环境变量 PARALLEL_JOBS 配置）
    local PARALLEL_JOBS=${PARALLEL_JOBS:-5}
    print_info "📊 并行处理模式：最多同时处理 $PARALLEL_JOBS 个仓库"
    print_info "💡 提示：网络带宽越高，并行化效果越好。如遇问题可设置 PARALLEL_JOBS=1 使用串行模式"
    echo ""
    
    # 记录所有失败的仓库（用于最后统一重试）
    declare -ga all_failed_repos=()
    # 记录所有失败的仓库和错误信息（用于最终日志）
    declare -ga all_failed_logs=()
    
    # 第一步：优先处理所有分组的缺失仓库（需要克隆的）
    local total_missing_count=0
    for group_folder in "${!global_repos_to_clone[@]}"; do
        local repos_list="${global_repos_to_clone[$group_folder]}"
        if [ -n "$repos_list" ]; then
            local repos_array
            string_to_array repos_array "$repos_list"
            total_missing_count=$((total_missing_count + ${#repos_array[@]}))
        fi
    done
    
    if [ "$total_missing_count" -gt 0 ]; then
        print_step "【优先级最高】同步所有缺失的仓库（共 $total_missing_count 个）..."
        print_info "   缺失的仓库将优先处理，完成后才会更新已存在的仓库"
        echo ""
        
        # 收集所有需要克隆的仓库信息（用于并行处理）
        local -a all_clone_tasks=()
        local global_index=0
        
        for group_folder in "${!global_repos_to_clone[@]}"; do
            local group_name="${group_names[$group_folder]}"
            local repos_list="${global_repos_to_clone[$group_folder]}"
            
            if [ -z "$repos_list" ]; then
                continue
            fi
            
            local repos_array
            string_to_array repos_array "$repos_list"
            
            for repo_info in "${repos_array[@]}"; do
                ((global_index++))
                # 格式：repo_full|repo_name|group_folder|group_name|global_index
                IFS='|' read -r repo_full repo_name <<< "$repo_info"
                all_clone_tasks+=("$repo_full|$repo_name|$group_folder|$group_name|$global_index")
            done
        done
        
        # 并行执行克隆任务
        local active_jobs=0
        local task_index=0
        local temp_dir=$(mktemp -d)
        local -a job_pids=()
        
        print_info "开始并行克隆（并发数: $PARALLEL_JOBS）..."
        echo ""
        
        while [ $task_index -lt ${#all_clone_tasks[@]} ] || [ $active_jobs -gt 0 ]; do
            # 更新活跃任务数（重新计算）
            active_jobs=0
            for pid in "${job_pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    ((active_jobs++))
                fi
            done
            # 启动新任务（如果还有待处理任务且未达到并发限制）
            while [ $active_jobs -lt $PARALLEL_JOBS ] && [ $task_index -lt ${#all_clone_tasks[@]} ]; do
                local task_info="${all_clone_tasks[$task_index]}"
                # 格式：repo_full|repo_name|group_folder|group_name|global_index
                IFS='|' read -r repo_full repo_name group_folder group_name global_index <<< "$task_info"
                
                local repo_path="$group_folder/$repo_name"
                local log_file="$temp_dir/clone_${task_index}.log"
                
                # 后台执行克隆任务（注意：在后台块中需要重新声明变量以确保正确传递）
                (
                    # 重新读取变量，确保在子shell中正确传递
                    local repo_full_var="$repo_full"
                    local group_folder_var="$group_folder"
                    local repo_name_var="$repo_name"
                    local group_name_var="$group_name"
                    local global_index_var="$global_index"
                    local total_missing_count_var="$total_missing_count"
                    
                    # 在子shell中重新构建路径，确保路径正确
                    local repo_path_var="$group_folder_var/$repo_name_var"
                    
                    echo "[$global_index_var/$total_missing_count_var] 开始克隆: $repo_name_var (分组: $group_name_var)"
                    echo "  目标路径: $repo_path_var" >> "$log_file"
                    clone_repo "$repo_full_var" "$repo_path_var" "$global_index_var" "$total_missing_count_var" "all_failed_logs"
                    local result=$?
                    echo "result:$result" >> "$log_file"
                    # 注意：统计更新在并行环境下可能有竞争，最后统一汇总
                    if [ "$result" -ne 0 ]; then
                        echo "failed:$repo_full_var|$repo_name_var|$group_folder_var" >> "$log_file"
                    fi
                ) >> "$log_file" 2>&1 &
                
                local pid=$!
                job_pids+=($pid)
                ((active_jobs++))
                ((task_index++))
            done
            
            # 检查并更新活跃任务数（每次循环重新计算，确保准确）
            local new_active=0
            for pid in "${job_pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    ((new_active++))
                fi
            done
            active_jobs=$new_active
            
            # 如果达到并发上限，短暂等待
            if [ $active_jobs -ge $PARALLEL_JOBS ] && [ $task_index -lt ${#all_clone_tasks[@]} ]; then
                sleep 0.3
            fi
        done
        
        # 等待所有任务完成并汇总结果
        for pid in "${job_pids[@]}"; do
            wait "$pid" 2>/dev/null || true
        done
        
        # 读取所有日志文件，汇总结果和失败信息
        for log_file in "$temp_dir"/clone_*.log; do
            if [ -f "$log_file" ]; then
                # 输出日志（除了结果行）
                grep -v "^result:\|^failed:" "$log_file" >&2 || true
                
                # 提取结果并更新统计
                local result=$(grep "^result:" "$log_file" | sed 's/^result://' || echo "1")
                local file_idx=$(basename "$log_file" | sed -n 's/clone_\([0-9]*\)\.log/\1/p')
                if [ -n "$file_idx" ] && [ -n "${all_clone_tasks[$file_idx]}" ]; then
                    local task_info="${all_clone_tasks[$file_idx]}"
                    # 格式：repo_full|repo_name|group_folder|group_name|global_index
                    IFS='|' read -r repo_full repo_name group_folder group_name global_index <<< "$task_info"
                    local repo_path="$group_folder/$repo_name"
                    update_sync_statistics "$repo_path" "$result"
                fi
                
                # 提取失败信息
                local failed_info=$(grep "^failed:" "$log_file" | sed 's/^failed://' || echo "")
                if [ -n "$failed_info" ]; then
                    all_failed_repos+=("$failed_info")
                fi
            fi
        done
        
        rm -rf "$temp_dir"
        
        echo ""
        print_success "所有缺失仓库同步完成（$total_missing_count 个）"
        echo ""
    fi
    
    # 第二步：处理所有分组的更新仓库（已存在的）
    local total_update_count=0
    for group_folder in "${!global_repos_to_update[@]}"; do
        local repos_list="${global_repos_to_update[$group_folder]}"
        if [ -n "$repos_list" ]; then
            local repos_array
            string_to_array repos_array "$repos_list"
            total_update_count=$((total_update_count + ${#repos_array[@]}))
        fi
    done
    
        if [ "$total_update_count" -gt 0 ]; then
        if [ "$total_missing_count" -gt 0 ]; then
            print_step "【第二步】更新所有已存在的仓库（共 $total_update_count 个）..."
            print_info "   所有缺失的仓库已处理完成，开始更新已存在的仓库"
        else
            print_step "更新所有已存在的仓库（共 $total_update_count 个）..."
        fi
        echo ""
        
        # 收集所有需要更新的仓库信息（用于并行处理）
        local -a all_update_tasks=()
        local global_index=0
        
        for group_folder in "${!global_repos_to_update[@]}"; do
            local group_name="${group_names[$group_folder]}"
            local repos_list="${global_repos_to_update[$group_folder]}"
            
            if [ -z "$repos_list" ]; then
                continue
            fi
            
            local repos_array
            string_to_array repos_array "$repos_list"
            
            for repo_info in "${repos_array[@]}"; do
                ((global_index++))
                # 格式：repo_full|repo_name|group_folder|group_name|global_index
                IFS='|' read -r repo_full repo_name <<< "$repo_info"
                all_update_tasks+=("$repo_full|$repo_name|$group_folder|$group_name|$global_index")
            done
        done
        
        # 并行执行更新任务
        local active_jobs=0
        local task_index=0
        local temp_dir=$(mktemp -d)
        local -a job_pids=()
        
        print_info "开始并行更新（并发数: $PARALLEL_JOBS）..."
        echo ""
        
        while [ $task_index -lt ${#all_update_tasks[@]} ] || [ $active_jobs -gt 0 ]; do
            # 启动新任务（如果还有待处理任务且未达到并发限制）
            while [ $active_jobs -lt $PARALLEL_JOBS ] && [ $task_index -lt ${#all_update_tasks[@]} ]; do
                local task_info="${all_update_tasks[$task_index]}"
                # 格式：repo_full|repo_name|group_folder|group_name|global_index
                IFS='|' read -r repo_full repo_name group_folder group_name global_index <<< "$task_info"
                
                local repo_path="$group_folder/$repo_name"
                local log_file="$temp_dir/update_${task_index}.log"
                
                # 后台执行更新任务（注意：在后台块中需要重新声明变量以确保正确传递）
                (
                    # 重新读取变量，确保在子shell中正确传递
                    local repo_full_var="$repo_full"
                    local repo_path_var="$repo_path"
                    local group_folder_var="$group_folder"
                    local repo_name_var="$repo_name"
                    local group_name_var="$group_name"
                    local global_index_var="$global_index"
                    local total_update_count_var="$total_update_count"
                    
                    echo "[$global_index_var/$total_update_count_var] 开始更新: $repo_name_var (分组: $group_name_var)"
                    update_repo "$repo_full_var" "$repo_path_var" "$group_folder_var" "$global_index_var" "$total_update_count_var" "all_failed_logs"
                    local result=$?
                    echo "result:$result" >> "$log_file"
                    if [ "$result" -ne 0 ] && [ "$result" -ne 2 ]; then
                        echo "failed:$repo_full_var|$repo_name_var|$group_folder_var" >> "$log_file"
                    fi
                ) >> "$log_file" 2>&1 &
                
                local pid=$!
                job_pids+=($pid)
                ((active_jobs++))
                ((task_index++))
            done
            
            # 检查并更新活跃任务数（每次循环重新计算，确保准确）
            local new_active=0
            for pid in "${job_pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    ((new_active++))
                fi
            done
            active_jobs=$new_active
            
            # 如果达到并发上限，短暂等待（让已完成的任务有机会被检测到）
            if [ $active_jobs -ge $PARALLEL_JOBS ]; then
                sleep 0.3
            fi
        done
        
        # 等待所有任务完成并汇总结果
        for pid in "${job_pids[@]}"; do
            wait "$pid" 2>/dev/null || true
        done
        
        # 读取所有日志文件，汇总结果和失败信息
        for log_file in "$temp_dir"/update_*.log; do
            if [ -f "$log_file" ]; then
                # 输出日志（除了结果行）
                grep -v "^result:\|^failed:" "$log_file" >&2 || true
                
                # 提取结果并更新统计
                local result=$(grep "^result:" "$log_file" | sed 's/^result://' || echo "1")
                local file_idx=$(basename "$log_file" | sed -n 's/update_\([0-9]*\)\.log/\1/p')
                if [ -n "$file_idx" ] && [ -n "${all_update_tasks[$file_idx]}" ]; then
                    local task_info="${all_update_tasks[$file_idx]}"
                    # 格式：repo_full|repo_name|group_folder|group_name|global_index
                    IFS='|' read -r repo_full repo_name group_folder group_name global_index <<< "$task_info"
                    local repo_path="$group_folder/$repo_name"
                    update_sync_statistics "$repo_path" "$result"
                fi
                
                # 提取失败信息
                local failed_info=$(grep "^failed:" "$log_file" | sed 's/^failed://' || echo "")
                if [ -n "$failed_info" ]; then
                    all_failed_repos+=("$failed_info")
                fi
            fi
        done
        
        rm -rf "$temp_dir"
        
        echo ""
        print_success "所有已存在仓库更新完成（$total_update_count 个）"
        echo ""
    fi
    
    # 最后统一重试：所有分组完成后，统一重试所有失败的仓库
    if [ ${#all_failed_repos[@]} -gt 0 ]; then
        echo ""
        echo "=================================================="
        print_info "所有分组同步完成，发现 ${#all_failed_repos[@]} 个失败的仓库，进行统一重试..."
        echo "=================================================="
        echo ""
        
        local retry_index=0
        local retry_success_count=0
        for failed_repo in "${all_failed_repos[@]}"; do
            IFS='|' read -r repo_full repo_name group_folder <<< "$failed_repo"
            ((retry_index++))
            
            if retry_repo_sync "$repo_full" "$repo_name" "$group_folder" "${#all_failed_repos[@]}" "$retry_index" "all_failed_logs"; then
                ((retry_success_count++))
            fi
        done
        
        # 更新失败统计（重试成功的应该从失败计数中减去）
        # 注意：retry_repo_sync 内部已经调用了 update_sync_statistics 来增加成功计数
        # 但第一次失败时已经统计为失败，所以需要减少失败计数
        if [ "$retry_success_count" -gt 0 ]; then
            SYNC_STATS_FAIL=$((SYNC_STATS_FAIL - retry_success_count))
            print_success "重试成功恢复 $retry_success_count 个仓库"
        fi
        
        local final_failed_count=$((${#all_failed_repos[@]} - retry_success_count))
        echo ""
        if [ "$final_failed_count" -gt 0 ]; then
            print_warning "重试完成，仍有 $final_failed_count 个仓库失败"
        else
            print_success "重试完成，所有仓库已成功同步"
        fi
        echo ""
    fi
    
    # 保存错误日志数组名供后续使用
    declare -g ALL_FAILED_LOGS_ARRAY=all_failed_logs
}

# ============================================
# 主函数
# ============================================

main() {
    # 1. 初始化同步环境
    initialize_sync
    
    # 2. 初始化缓存（性能优化：一次性加载所有数据）
    echo ""
    print_step "初始化缓存系统..."
    init_config_cache || exit 1
    init_repo_cache || exit 1
    echo ""
    
    # 3. 列出所有可用分组
    list_groups
    echo ""
    
    # 4. 获取所有分组用于同步（使用缓存）
    print_info "准备同步所有分组..."
    local all_groups_output=$(get_all_groups_for_sync)
    if [ $? -ne 0 ]; then
        exit 1
    fi
    
    local groups_array
    string_to_array groups_array "$all_groups_output"
    
    if [ ${#groups_array[@]} -eq 0 ]; then
        print_error "没有找到任何分组"
        exit 1
    fi
    
    print_info "找到 ${#groups_array[@]} 个分组，开始同步..."
    echo ""
    
    # 5. 全局扫描差异，分析所有仓库状态
    scan_global_diff "${groups_array[@]}"
    
    # 6. 初始化本地仓库缓存（用于后续清理和报告）
    init_local_repo_cache
    
    # 7. 执行同步（优先处理缺失的仓库，再处理更新的）
    execute_sync "${groups_array[@]}"
    
    # 8. 构建同步仓库映射（用于清理检查，使用缓存）
    declare -A sync_repos_map
    build_sync_repos_map sync_repos_map
    
    # 9. 清理删除远程已不存在的本地仓库（使用缓存）
    cleanup_deleted_repos group_folders sync_repos_map
    
    # 10. 输出最终统计
    print_final_summary
    
    # 11. 显示失败仓库详情
    if [ -n "$ALL_FAILED_LOGS_ARRAY" ]; then
        local -n failed_logs=$ALL_FAILED_LOGS_ARRAY
        print_failed_repos_details failed_logs
    fi
    
    # 12. 比较远程和本地差异，生成详细报告
    if [ -n "$ALL_FAILED_LOGS_ARRAY" ]; then
        local -n failed_logs=$ALL_FAILED_LOGS_ARRAY
        compare_remote_local_diff failed_logs
    else
        declare -a empty_failed_logs=()
        compare_remote_local_diff empty_failed_logs
    fi
}

# 执行主函数
main "$@"
