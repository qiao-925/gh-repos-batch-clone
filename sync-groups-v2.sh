#!/bin/bash
# GitHub 仓库按分组同步脚本（跨平台版本）
# 功能：按分组同步 GitHub 仓库，保持本地仓库与远程仓库完全同步（增删改查）
# 使用方法: 
#   bash sync-groups.sh <分组名1> [分组名2] ...
#   分组名可以是完整名称（如"Go 学习"）或代号（如"597.9"或"597.9高地"）
#   使用 --list 或 -l 查看所有可用分组
#   使用 -a 或 --all 同步所有分组
#
# 加速配置：
#   1. 浅克隆：自动启用 --depth 1（只克隆最新提交）
#   2. 单分支克隆：自动启用 --single-branch（只克隆默认分支）
#   3. Git 缓冲区：自动配置 500MB HTTP 缓冲区
#   4. GitHub 镜像站：在脚本中设置 GITHUB_MIRROR 变量（见下方配置）

# ============================================================================
# 一、配置和常量定义
# ============================================================================

CONFIG_FILE="REPO-GROUPS.md"

# GitHub 镜像站配置（可选，留空则使用官方 GitHub）
# 常用镜像站：
#   - https://github.com.cnpmjs.org (CNPM 镜像，可能在 Windows 上有 SSL 问题)
#   - https://hub.fastgit.xyz (FastGit)
#   - https://ghproxy.com (GitHub Proxy)
#   - https://mirror.ghproxy.com
# 设置为空字符串 "" 则直接使用官方 GitHub
# 注意：如果镜像站连接失败，脚本会自动回退到官方 GitHub
GITHUB_MIRROR=""

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================================================
# 二、日志输出函数
# ============================================================================

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_debug() {
    # Debug 模式已关闭
    :
}

print_step() {
    echo -e "${BLUE}→${NC} $1"
}

# ============================================================================
# 三、配置文件解析函数
# ============================================================================

# 解析分组行，提取分组名和代号
# 格式: ## 分组名 <!-- 代号 -->
parse_group_line() {
    local line=$1
    if echo "$line" | grep -qE '^##[[:space:]]+'; then
        local full_line=$(echo "$line" | sed 's/^##[[:space:]]*//')
        local group_name=$(echo "$full_line" | sed 's/[[:space:]]*<!--.*-->.*$//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        local alias=""
        if echo "$full_line" | grep -qE '<!--.*-->'; then
            alias=$(echo "$full_line" | sed -n 's/.*<!--[[:space:]]*\([^[:space:]]*[^[:space:]]\)[[:space:]]*-->.*/\1/p' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        fi
        echo "$group_name|$alias"
    fi
}

# 查找分组名（支持完整名称或代号）
find_group_name() {
    local input=$1
    local found_name=""
    
    print_debug "查找分组: 输入='$input'"
    while IFS= read -r line; do
        local parsed=$(parse_group_line "$line")
        if [ -n "$parsed" ]; then
            IFS='|' read -r group_name alias <<< "$parsed"
            print_debug "  比较: 分组名='$group_name', 代号='$alias'"
            if [ "$group_name" = "$input" ] || [ "$alias" = "$input" ]; then
                found_name="$group_name"
                print_debug "  匹配成功: 找到分组 '$group_name'"
                break
            fi
            # 支持去掉"高地"后缀的匹配
            if [ -n "$alias" ]; then
                local alias_without="${alias%高地}"
                if [ "$alias_without" != "$alias" ] && [ "$alias_without" = "$input" ]; then
                    found_name="$group_name"
                    print_debug "  匹配成功（去掉'高地'后缀）: 找到分组 '$group_name'"
                    break
                fi
            fi
        fi
    done < "$CONFIG_FILE"
    
    if [ -z "$found_name" ]; then
        print_debug "  未找到匹配的分组"
    fi
    echo "$found_name"
}

# 获取分组文件夹名
get_group_folder() {
    local group_name=$1
    local group_alias=""
    
    while IFS= read -r line; do
        local parsed=$(parse_group_line "$line")
        if [ -n "$parsed" ]; then
            IFS='|' read -r current_group alias <<< "$parsed"
            if [ "$current_group" = "$group_name" ]; then
                group_alias="$alias"
                break
            fi
        fi
    done < "$CONFIG_FILE"
    
    local folder="${group_alias:-$group_name}"
    echo "${folder%高地}"
}

# 获取指定分组的仓库列表
get_group_repos() {
    local group_name=$1
    local in_group=false
    local repos=()
    
    print_debug "获取分组 '$group_name' 的仓库列表"
    while IFS= read -r line; do
        local parsed=$(parse_group_line "$line")
        if [ -n "$parsed" ]; then
            IFS='|' read -r current_group alias <<< "$parsed"
            if [ "$current_group" = "$group_name" ]; then
                in_group=true
                print_debug "  进入分组 '$group_name'"
            else
                in_group=false
            fi
        elif [ "$in_group" = true ] && echo "$line" | grep -qE '^-[[:space:]]+'; then
            local repo_name=$(echo "$line" | sed 's/^-[[:space:]]*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            if [ -n "$repo_name" ]; then
                repos+=("$repo_name")
                print_debug "  找到仓库: $repo_name"
            fi
        fi
    done < "$CONFIG_FILE"
    
    print_debug "分组 '$group_name' 共有 ${#repos[@]} 个仓库"
    printf '%s\n' "${repos[@]}"
}

# 列出所有分组
list_groups() {
    print_step "正在读取配置文件: $CONFIG_FILE"
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "分类文档不存在: $CONFIG_FILE"
        print_info "请参考 REPO-GROUPS.md.example 创建分类文档"
        print_info "或使用 PROMPT.md 中的 prompt 让 AI 生成"
        return
    fi
    print_debug "配置文件存在，开始解析分组"
    print_info "可用分组："
    local group_count=0
    while IFS= read -r line; do
        local parsed=$(parse_group_line "$line")
        if [ -n "$parsed" ]; then
            IFS='|' read -r group_name alias <<< "$parsed"
            if [ -n "$alias" ]; then
                echo "  $group_name (代号: $alias)"
            else
                echo "  $group_name"
            fi
            ((group_count++))
            print_debug "解析到分组: $group_name (代号: $alias)"
        fi
    done < "$CONFIG_FILE"
    print_info "共找到 $group_count 个分组"
}

# 获取所有分组名称（用于 -a 参数）
get_all_group_names() {
    if [ ! -f "$CONFIG_FILE" ]; then
        return 1
    fi
    
    local group_names=()
    while IFS= read -r line; do
        local parsed=$(parse_group_line "$line")
        if [ -n "$parsed" ]; then
            IFS='|' read -r group_name alias <<< "$parsed"
            group_names+=("$group_name")
        fi
    done < "$CONFIG_FILE"
    
    printf '%s\n' "${group_names[@]}"
}

# ============================================================================
# 四、GitHub 仓库操作函数
# ============================================================================

# 初始化 GitHub 连接（添加 SSH 密钥）
init_github_connection() {
    print_step "检查 SSH 配置..."
    if [ ! -f ~/.ssh/known_hosts ] || ! grep -q "github.com" ~/.ssh/known_hosts 2>/dev/null; then
        print_info "正在添加 GitHub 主机密钥..."
        mkdir -p ~/.ssh
        ssh-keyscan -t rsa,ecdsa,ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null || true
        print_debug "GitHub 主机密钥已添加到 known_hosts"
    else
        print_debug "GitHub 主机密钥已存在"
    fi
    
    # 配置 Git 加速选项
    print_step "配置 Git 加速选项..."
    git config --global http.postBuffer 524288000 2>/dev/null || true  # 500MB 缓冲区
    git config --global http.lowSpeedLimit 0 2>/dev/null || true
    git config --global http.lowSpeedTime 0 2>/dev/null || true
    git config --global core.preloadindex true 2>/dev/null || true
    git config --global core.fscache true 2>/dev/null || true
    print_debug "Git 加速配置已应用"
    
    # 显示镜像站配置信息
    if [ -n "$GITHUB_MIRROR" ] && [ "$GITHUB_MIRROR" != "" ]; then
        print_info "使用 GitHub 镜像站: $GITHUB_MIRROR"
        print_debug "镜像站已启用，克隆速度将显著提升"
    else
        print_info "使用官方 GitHub (github.com)"
        print_debug "如需加速，可在脚本中设置 GITHUB_MIRROR 变量"
    fi
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

# ============================================================================
# 五、仓库同步操作函数
# ============================================================================

# 将 GitHub URL 转换为镜像站 URL
convert_to_mirror_url() {
    local repo=$1
    local repo_url=""
    
    # 如果是 SSH URL，保持原样（镜像站通常不支持 SSH）
    if [[ "$repo" == *"@"* ]] || [[ "$repo" == *"git@"* ]]; then
        repo_url="$repo"
        print_debug "  使用 SSH URL: $repo_url"
        echo "$repo_url"
        return 0
    fi
    
    # 构建 HTTPS URL
    if [ -n "$GITHUB_MIRROR" ] && [ "$GITHUB_MIRROR" != "" ]; then
        # 使用镜像站
        repo_url="${GITHUB_MIRROR}/$repo.git"
        print_debug "  使用镜像站 URL: $repo_url"
    else
        # 使用官方 GitHub
        repo_url="https://github.com/$repo.git"
        print_debug "  使用官方 GitHub URL: $repo_url"
    fi
    
    echo "$repo_url"
}

# 克隆仓库（使用加速选项，自动回退机制）
clone_repo() {
    local repo=$1
    local repo_path=$2
    local current_index=$3
    local total_sync=$4
    
    echo "[$current_index/$total_sync] [克隆] $repo -> $(dirname $repo_path)/..."
    print_debug "  开始克隆仓库: $repo -> $repo_path"
    
    local clone_exit_code=1
    local repo_url=""
    local official_url="https://github.com/$repo.git"
    
    # 如果配置了镜像站，先尝试镜像站
    if [ -n "$GITHUB_MIRROR" ] && [ "$GITHUB_MIRROR" != "" ]; then
        repo_url="${GITHUB_MIRROR}/$repo.git"
        print_debug "  尝试镜像站: $repo_url"
        
        # 尝试浅克隆
        git clone --depth 1 --single-branch "$repo_url" "$repo_path" 2>&1
        clone_exit_code=$?
        
        # 如果镜像站失败（SSL/TLS 错误或其他网络错误），回退到官方 GitHub
        if [ $clone_exit_code -ne 0 ]; then
            print_warning "  镜像站克隆失败，回退到官方 GitHub..."
            # 清理可能创建的部分目录
            [ -d "$repo_path" ] && rm -rf "$repo_path" 2>/dev/null || true
            repo_url="$official_url"
            print_debug "  使用官方 GitHub: $repo_url"
        else
            echo "✓ 成功（镜像站）"
            print_debug "  镜像站克隆成功"
            return 0
        fi
    else
        # 直接使用官方 GitHub
        repo_url="$official_url"
        print_debug "  使用官方 GitHub: $repo_url"
    fi
    
    # 使用官方 GitHub 进行浅克隆
    print_debug "  执行浅克隆: git clone --depth 1 --single-branch"
    git clone --depth 1 --single-branch "$repo_url" "$repo_path" 2>&1
    clone_exit_code=$?
    
    # 如果浅克隆失败，尝试完整克隆
    if [ $clone_exit_code -ne 0 ]; then
        print_debug "  浅克隆失败，尝试完整克隆..."
        [ -d "$repo_path" ] && rm -rf "$repo_path" 2>/dev/null || true
        git clone "$repo_url" "$repo_path" 2>&1
        clone_exit_code=$?
    fi
    
    if [ $clone_exit_code -eq 0 ]; then
        echo "✓ 成功"
        print_debug "  克隆成功"
        return 0
    else
        echo "✗ 失败"
        print_error "  克隆失败，退出代码: $clone_exit_code"
        return 1
    fi
}

# 更新已有仓库
update_repo() {
    local repo=$1
    local repo_path=$2
    local group_folder=$3
    local current_index=$4
    local total_sync=$5
    
    echo -n "[$current_index/$total_sync] [更新] $repo ($group_folder)... "
    print_debug "  仓库目录已存在: $repo_path"
    
    cd "$repo_path" || return 1
    
    # 检查是否在分支上，如果不在则切换到默认分支
    local current_branch=$(git symbolic-ref -q HEAD 2>&1)
    print_debug "    当前分支状态: ${current_branch:-detached HEAD}"
    
    if [ -z "$current_branch" ]; then
        print_debug "    检测到 detached HEAD，尝试切换到默认分支"
        local default_branch_output=$(git remote show origin 2>&1 | grep "HEAD branch" | sed 's/.*: //' || echo "")
        local default_branch="${default_branch_output:-main}"
        print_debug "    默认分支: $default_branch"
        
        print_debug "    执行: git checkout -b $default_branch"
        local checkout_output=$(git checkout -b "$default_branch" 2>&1)
        local checkout_exit=$?
        if [ $checkout_exit -ne 0 ]; then
            print_debug "    创建分支失败，尝试切换: git checkout $default_branch"
            checkout_output=$(git checkout "$default_branch" 2>&1)
            checkout_exit=$?
        fi
        
        if [ $checkout_exit -eq 0 ]; then
            print_debug "    已切换到分支: $default_branch"
            # 显示 checkout 输出（静默，不影响进度显示）
            if [ -n "$checkout_output" ]; then
                echo "$checkout_output" | while IFS= read -r line; do
                    print_debug "    $line"
                done
            fi
        else
            print_warning "    切换分支失败: $checkout_output"
            print_warning "    继续尝试拉取"
        fi
    fi
    
    # 获取当前分支名并拉取
    local branch=$(git rev-parse --abbrev-ref HEAD 2>&1 || echo "main")
    print_debug "    准备拉取分支: $branch"
    
    # 获取拉取前的提交哈希
    local before_hash=$(git rev-parse HEAD 2>&1 || echo "")
    print_debug "    拉取前提交: ${before_hash:0:8}"
    
    # 直接执行 git pull，显示自带进度（与原脚本一致，静默执行）
    git pull origin "$branch" --quiet 2>/dev/null || git pull --quiet
    
    if [ $? -eq 0 ]; then
        local after_hash=$(git rev-parse HEAD 2>&1 || echo "")
        print_debug "    拉取后提交: ${after_hash:0:8}"
        
        if [ "$before_hash" != "$after_hash" ] && [ -n "$before_hash" ] && [ -n "$after_hash" ]; then
            print_debug "    仓库已更新"
        else
            print_debug "    仓库已是最新"
        fi
        echo "✓ 成功"
        cd ../.. || true
        return 0
    else
        echo "✗ 失败"
        cd ../.. || true
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
    
    # 创建分组文件夹
    if [ ! -d "$group_folder" ]; then
        mkdir -p "$group_folder"
        print_info "创建分组文件夹: $group_folder"
    fi
    
    local repo_path="$group_folder/$repo_name"
    
    # 检查是否已存在
    if [ -d "$repo_path" ]; then
        # 检查是否是 git 仓库
        if [ -d "$repo_path/.git" ]; then
            update_repo "$repo" "$repo_path" "$group_folder" "$current_index" "$total_sync"
            return $?
        else
            echo "[$current_index/$total_sync] [跳过] $repo - 目录已存在但不是 git 仓库"
            print_warning "  目录 $repo_path 存在但不是 git 仓库，跳过"
            return 2
        fi
    else
        clone_repo "$repo" "$repo_path" "$current_index" "$total_sync"
        return $?
    fi
}

# 批量同步仓库
sync_repositories() {
    local -n repos_ref=$1
    local -n repo_to_group_ref=$2
    
    local total_sync=${#repos_ref[@]}
    local current_index=0
    local success_count=0
    local update_count=0
    local fail_count=0
    
    print_step "开始同步仓库（共 $total_sync 个）..."
    
    for repo in "${repos_ref[@]}"; do
        repo=$(echo $repo | tr -d '\r\n')
        local repo_name=$(basename $repo)
        local group_folder="${repo_to_group_ref[$repo]}"
        
        if [ -z "$group_folder" ]; then
            print_warning "跳过仓库 $repo: 未找到对应的分组文件夹"
            continue
        fi
        
        ((current_index++))
        
        local result
        sync_single_repo "$repo" "$repo_name" "$group_folder" "$current_index" "$total_sync"
        result=$?
        
        case $result in
            0)
                if [ -d "$group_folder/$repo_name/.git" ] && [ -d "$group_folder/$repo_name" ]; then
                    # 检查是更新还是克隆
                    if [ -d "$group_folder/$repo_name/.git/refs/heads" ]; then
                        ((update_count++))
                    else
                        ((success_count++))
                    fi
                fi
                ;;
            2)
                ((fail_count++))
                ;;
            *)
                ((fail_count++))
                ;;
        esac
    done
    
    echo ""
    echo "=================================================="
    echo "同步操作完成（增/改）"
    echo "新增: $success_count"
    echo "更新: $update_count"
    echo "失败: $fail_count"
    echo "=================================================="
    echo ""
    
    # 返回统计信息（通过全局变量）
    SYNC_STATS_SUCCESS=$success_count
    SYNC_STATS_UPDATE=$update_count
    SYNC_STATS_FAIL=$fail_count
}

# ============================================================================
# 六、清理删除函数
# ============================================================================

# 清理远程已删除的本地仓库
cleanup_deleted_repos() {
    local -n group_folders_ref=$1
    local -n sync_repos_map_ref=$2
    
    print_step "检查需要删除的本地仓库（远程已不存在）..."
    local delete_count=0
    
    # 获取仓库所有者（用于检查远程仓库是否存在）
    local repo_owner=$(gh api user --jq '.login' 2>/dev/null || echo "")
    print_debug "仓库所有者: $repo_owner"
    
    # 遍历所有分组文件夹
    local check_dirs=()
    for group_folder in "${!group_folders_ref[@]}"; do
        if [ -d "$group_folder" ]; then
            print_debug "检查分组文件夹: $group_folder"
            for dir in "$group_folder"/*; do
                [ -d "$dir" ] && check_dirs+=("$dir")
            done
        fi
    done
    
    print_debug "找到 ${#check_dirs[@]} 个本地目录需要检查"
    
    # 遍历目录
    for local_dir in "${check_dirs[@]}"; do
        local_dir=${local_dir%/}
        
        # 跳过非目录或非 git 仓库
        [ ! -d "$local_dir" ] && continue
        [ ! -d "$local_dir/.git" ] && continue
        
        local repo_name=$(basename "$local_dir")
        local repo_path="$local_dir"
        
        print_debug "检查本地仓库: $repo_path"
        
        # 检查是否在要同步的仓库列表中
        if [ -z "${sync_repos_map_ref[$repo_path]}" ]; then
            # 如果不在要同步的分组中，检查是否在远程还存在
            if [ -n "$repo_owner" ] && gh repo view "$repo_owner/$repo_name" &>/dev/null; then
                print_debug "  仓库 $repo_name 还在远程，只是不在当前同步的分组中，跳过"
                continue
            else
                # 仓库已不存在，删除
                echo -n "[删除] $repo_path (远程仓库已不存在)... "
                local rm_output=$(rm -rf "$repo_path" 2>&1)
                local rm_exit=$?
                
                if [ $rm_exit -eq 0 ]; then
                    echo "✓ 已删除"
                    ((delete_count++))
                    print_debug "  已删除: $repo_path"
                else
                    echo "✗ 删除失败"
                    print_error "  删除失败: $repo_path"
                    if [ -n "$rm_output" ]; then
                        print_error "  错误信息: $rm_output"
                    fi
                fi
            fi
        else
            print_debug "  仓库 $repo_name 在同步列表中，保留"
        fi
    done
    
    if [ $delete_count -eq 0 ]; then
        print_info "没有需要删除的本地仓库。"
    else
        echo ""
        print_info "已删除 $delete_count 个本地仓库（远程已不存在）。"
    fi
    
    CLEANUP_STATS_DELETE=$delete_count
}

# ============================================================================
# 七、主执行流程
# ============================================================================

# 查找仓库的完整名称（owner/repo）
find_repo_full_name() {
    local repo_name=$1
    local repo_owner=$(gh api user --jq '.login' 2>/dev/null || echo "")
    
    if [ -z "$repo_owner" ]; then
        return 1
    fi
    
    # 尝试检查仓库是否存在
    if gh repo view "$repo_owner/$repo_name" &>/dev/null; then
        echo "$repo_owner/$repo_name"
        return 0
    fi
    
    return 1
}

# 直接同步分组中的仓库（查一个拉一个）
sync_group_repos() {
    local group_name=$1
    local group_folder=$2
    local group_repos=$3
    
    # 声明分组文件夹映射（用于清理）
    declare -gA group_folders
    declare -gA group_names
    group_folders["$group_folder"]=1
    group_names["$group_folder"]="$group_name"
    
    # 计算总数
    local total_count=$(echo "$group_repos" | grep -v '^$' | wc -l | tr -d ' ')
    local current_index=0
    
    print_step "开始同步分组 '$group_name'（共 $total_count 个仓库）..."
    
    while IFS= read -r repo_name; do
        # 去除首尾空白字符
        repo_name=$(echo "$repo_name" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        
        if [ -z "$repo_name" ]; then
            continue
        fi
        
        ((current_index++))
        
        # 查找仓库完整名称
        print_debug "  查找仓库: $repo_name"
        local repo_full=$(find_repo_full_name "$repo_name")
        
        if [ -z "$repo_full" ]; then
            echo "[$current_index/$total_count] [错误] $repo_name - 远程仓库不存在"
            print_error "    未找到远程仓库: $repo_name"
            ((SYNC_STATS_FAIL++))
            continue
        fi
        
        print_debug "    找到远程仓库: $repo_full"
        
        # 同步单个仓库
        local result
        sync_single_repo "$repo_full" "$repo_name" "$group_folder" "$current_index" "$total_count"
        result=$?
        
        case $result in
            0)
                # 检查是更新还是克隆
                if [ -d "$group_folder/$repo_name/.git" ] && [ -d "$group_folder/$repo_name" ]; then
                    # 检查仓库是否是新克隆的（通过检查是否有远程配置）
                    if git -C "$group_folder/$repo_name" remote get-url origin &>/dev/null; then
                        # 已存在的仓库，是更新
                        ((SYNC_STATS_UPDATE++))
                    else
                        # 新克隆的仓库
                        ((SYNC_STATS_SUCCESS++))
                    fi
                fi
                ;;
            2)
                ((SYNC_STATS_FAIL++))
                ;;
            *)
                ((SYNC_STATS_FAIL++))
                ;;
        esac
    done <<< "$group_repos"
}

# 主函数
main() {
    # 1. 参数解析 - 如果是 --list，直接列出分组并退出
    if [ $# -eq 0 ] || [ "$1" = "--list" ] || [ "$1" = "-l" ]; then
        list_groups
        exit 0
    fi
    
    # 处理 -a 或 --all 参数：同步所有分组
    if [ "$1" = "-a" ] || [ "$1" = "--all" ]; then
        print_info "将同步所有分组..."
        
        # 读取所有分组名称
        local all_groups=$(get_all_group_names)
        if [ -z "$all_groups" ]; then
            print_error "无法读取分组列表"
            exit 1
        fi
        
        # 将分组名称转换为数组
        local groups_array=()
        while IFS= read -r group; do
            groups_array+=("$group")
        done <<< "$all_groups"
        
        if [ ${#groups_array[@]} -eq 0 ]; then
            print_error "配置文件中没有找到任何分组"
            exit 1
        fi
        
        print_info "找到 ${#groups_array[@]} 个分组"
        
        # 替换参数，将 -a 替换为所有分组名
        set -- "${groups_array[@]}"
    fi
    
    # 2. 检查配置文件
    print_step "检查配置文件..."
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "分类文档不存在: $CONFIG_FILE"
        print_info "请参考 REPO-GROUPS.md.example 创建分类文档"
        print_info "或使用 PROMPT.md 中的 prompt 让 AI 生成"
        exit 1
    fi
    print_success "配置文件存在: $CONFIG_FILE"
    
    # 3. 初始化 GitHub 连接
    init_github_connection
    
    # 4. 显示同步信息
    echo "=================================================="
    echo "GitHub 仓库分组同步工具"
    echo "=================================================="
    echo ""
    
    # 5. 初始化统计变量
    declare -g SYNC_STATS_SUCCESS=0
    declare -g SYNC_STATS_UPDATE=0
    declare -g SYNC_STATS_FAIL=0
    declare -gA group_folders
    declare -gA group_names
    
    # 6. 遍历每个分组，查一个拉一个
    for input_group in "$@"; do
        print_info "处理分组输入: '$input_group'"
        local group_name=$(find_group_name "$input_group")
        
        if [ -z "$group_name" ]; then
            print_error "未找到分组: $input_group"
            print_info "使用 --list 查看所有可用分组和代号"
            exit 1
        fi
        
        print_success "找到分组: '$group_name'"
        local group_folder=$(get_group_folder "$group_name")
        print_debug "分组文件夹: '$group_folder'"
        
        local group_repos=$(get_group_repos "$group_name")
        
        if [ -z "$group_repos" ]; then
            print_warning "分组 $group_name 中没有仓库"
            continue
        fi
        
        echo ""
        print_info "将同步分组: $group_name"
        echo ""
        
        # 同步这个分组的所有仓库（查一个拉一个）
        sync_group_repos "$group_name" "$group_folder" "$group_repos"
    done
    
    # 7. 构建同步仓库映射（用于清理检查）
    declare -A sync_repos_map
    # 遍历所有分组文件夹，收集已同步的仓库
    for group_folder in "${!group_folders[@]}"; do
        if [ -d "$group_folder" ]; then
            for dir in "$group_folder"/*; do
                if [ -d "$dir" ] && [ -d "$dir/.git" ]; then
                    local repo_name=$(basename "$dir")
                    sync_repos_map["$group_folder/$repo_name"]=1
                fi
            done
        fi
    done
    
    # 8. 清理删除远程已不存在的本地仓库
    cleanup_deleted_repos group_folders sync_repos_map
    
    # 10. 输出最终统计
    echo ""
    echo "=================================================="
    echo "✅ 同步完成！"
    echo "新增: ${SYNC_STATS_SUCCESS:-0}"
    echo "更新: ${SYNC_STATS_UPDATE:-0}"
    echo "删除: ${CLEANUP_STATS_DELETE:-0}"
    echo "失败: ${SYNC_STATS_FAIL:-0}"
    echo "=================================================="
}

# 执行主函数
main "$@"
