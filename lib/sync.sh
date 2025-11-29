#!/bin/bash
# 仓库同步操作函数

# 克隆仓库（完整克隆，带第一层重试）
clone_repo() {
    local repo=$1
    local repo_path=$2
    local current_index=$3
    local total_sync=$4
    local is_retry=${5:-false}
    local error_log_ref=${6:-""}
    
    if [ "$is_retry" = "true" ]; then
        echo "[$current_index/$total_sync] [克隆-重试] $repo -> $(dirname "$repo_path")/..." >&2
        print_info "  正在重试克隆仓库: $repo"
    else
        echo "[$current_index/$total_sync] [克隆] $repo -> $(dirname "$repo_path")/..." >&2
        print_info "  正在克隆仓库: $repo"
    fi
    print_info "  目标路径: $repo_path"
    
    local repo_url="https://github.com/$repo.git"
    print_info "  仓库 URL: $repo_url"
    
    # 使用官方 GitHub 进行完整克隆，直接执行让进度自然显示
    print_command "git clone \"$repo_url\" \"$repo_path\""
    print_operation_start "Git 克隆操作" "$repo"
    local clone_start_time=$(date +%s)
    
    # 直接执行 git clone，不捕获输出，让进度自然显示
    # 只在失败时捕获错误信息
    git clone "$repo_url" "$repo_path"
    local clone_exit_code=$?
    
    local clone_end_time=$(date +%s)
    local clone_duration=$((clone_end_time - clone_start_time))
    
    # 如果失败，获取错误信息
    local clone_output=""
    if [ $clone_exit_code -ne 0 ]; then
        # 失败时尝试获取错误信息（但可能已经输出到终端了）
        clone_output="克隆失败，退出代码: $clone_exit_code"
    fi
    
    if [ $clone_exit_code -eq 0 ]; then
        if [ "$is_retry" = "true" ]; then
            echo "✓ 成功（重试，耗时 ${clone_duration}秒）" >&2
        else
            echo "✓ 成功（耗时 ${clone_duration}秒）" >&2
        fi
        print_success "  克隆成功: $repo_path"
        return 0
    else
        # 第一层重试：如果失败且不是重试，立即重试一次
        if [ "$is_retry" != "true" ]; then
            print_warning "  克隆失败，立即重试一次..."
            sleep 1
            [ -d "$repo_path" ] && rm -rf "$repo_path" 2>/dev/null || true
            clone_repo "$repo" "$repo_path" "$current_index" "$total_sync" "true" "$error_log_ref"
            return $?
        else
            echo "✗ 失败（耗时 ${clone_duration}秒）" >&2
            # 错误信息已经在终端显示了，这里只记录基本错误
            local error_msg="${clone_output:-克隆失败，退出代码: $clone_exit_code}"
            print_error "  克隆失败: $error_msg"
            print_error "  请查看上方的错误信息"
            # 记录失败日志
            if [ -n "$error_log_ref" ]; then
                # 使用 nameref 安全地添加元素
                local -n error_log_array=$error_log_ref
                error_log_array+=("$repo|克隆失败|$error_msg")
            fi
            return 1
        fi
    fi
}

# 更新已有仓库（带第一层重试）
update_repo() {
    local repo=$1
    local repo_path=$2
    local group_folder=$3
    local current_index=$4
    local total_sync=$5
    local is_retry=${6:-false}
    local error_log_ref=${7:-""}
    
    if [ "$is_retry" = "true" ]; then
        echo -n "[$current_index/$total_sync] [更新-重试] $repo ($group_folder)... " >&2
        print_info "  正在重试更新仓库: $repo"
    else
        echo -n "[$current_index/$total_sync] [更新] $repo ($group_folder)... " >&2
        print_info "  正在更新仓库: $repo"
    fi
    print_info "  仓库路径: $repo_path"
    
    # 保存当前目录
    local original_dir=$(pwd)
    
    cd "$repo_path" || {
        local error_msg="无法进入仓库目录: $repo_path"
        print_error "  错误: $error_msg"
        if [ -n "$error_log_ref" ]; then
            # 使用 nameref 安全地添加元素
            local -n error_log_array=$error_log_ref
            error_log_array+=("$repo|更新失败|$error_msg")
        fi
        return 1
    }
    
    # 检查是否在分支上，如果不在则切换到默认分支
    print_command "git symbolic-ref -q HEAD"
    print_operation_start "检查当前分支状态" ""
    local current_branch=$(git symbolic-ref -q HEAD 2>&1)
    print_operation_end "检查当前分支状态" "success" "0" "${current_branch:-detached HEAD}"
    print_info "    当前分支状态: ${current_branch:-detached HEAD}"
    
    if [ -z "$current_branch" ]; then
        print_warning "    检测到 detached HEAD，尝试切换到默认分支"
        print_command "git remote show origin"
        print_operation_start "获取默认分支" ""
        local default_branch_output=$(git remote show origin 2>&1 | grep "HEAD branch" | sed 's/.*: //' || echo "")
        local default_branch="${default_branch_output:-main}"
        print_operation_end "获取默认分支" "success" "0" "$default_branch"
        print_info "    默认分支: $default_branch"
        
        print_command "git checkout -b $default_branch"
        print_operation_start "切换到默认分支" "$default_branch"
        local checkout_start=$(date +%s)
        local checkout_output=$(git checkout -b "$default_branch" 2>&1)
        local checkout_exit=$?
        if [ $checkout_exit -ne 0 ]; then
            print_warning "    创建分支失败，尝试切换: git checkout $default_branch"
            print_command "git checkout $default_branch"
            checkout_output=$(git checkout "$default_branch" 2>&1)
            checkout_exit=$?
        fi
        local checkout_end=$(date +%s)
        local checkout_duration=$((checkout_end - checkout_start))
        
        if [ $checkout_exit -eq 0 ]; then
            print_operation_end "切换到默认分支" "success" "$checkout_duration" "$default_branch"
            print_success "    已切换到分支: $default_branch"
        else
            print_operation_end "切换到默认分支" "fail" "$checkout_duration" "$checkout_output"
            print_warning "    切换分支失败: $checkout_output"
            print_warning "    继续尝试拉取（可能仍在 detached HEAD 状态）"
        fi
    fi
    
    # 获取当前分支名并拉取
    print_command "git rev-parse --abbrev-ref HEAD"
    print_operation_start "获取当前分支名" ""
    local branch=$(git rev-parse --abbrev-ref HEAD 2>&1 || echo "main")
    print_operation_end "获取当前分支名" "success" "0" "$branch"
    print_info "    准备拉取分支: $branch"
    
    # 获取拉取前的提交哈希
    print_command "git rev-parse HEAD"
    print_operation_start "获取当前提交哈希" ""
    local before_hash=$(git rev-parse HEAD 2>&1 || echo "")
    print_operation_end "获取当前提交哈希" "success" "0" "${before_hash:0:8}"
    print_info "    拉取前提交: ${before_hash:0:8}"
    
    # 直接执行 git pull，让进度自然显示
    print_command "git pull origin \"$branch\""
    print_operation_start "Git 拉取操作" "$repo (分支: $branch)"
    local pull_start_time=$(date +%s)
    
    # 先尝试从 origin 拉取，输出重定向到 stderr 避免被命令替换捕获
    # 注意：git pull 的进度信息会显示在终端（stderr），但不会被命令替换捕获
    git pull origin "$branch" >&2
    local pull_exit_code=$?
    
    # 如果从 origin 拉取失败，尝试直接拉取（可能 remote 名称不是 origin）
    if [ $pull_exit_code -ne 0 ]; then
        print_warning "    从 origin 拉取失败，尝试直接拉取..."
        print_command "git pull"
        git pull >&2
        pull_exit_code=$?
    fi
    
    local pull_end_time=$(date +%s)
    local pull_duration=$((pull_end_time - pull_start_time))
    
    # 如果失败，获取错误信息
    local pull_output=""
    if [ $pull_exit_code -ne 0 ]; then
        pull_output="拉取失败，退出代码: $pull_exit_code"
    fi
    
    if [ $pull_exit_code -eq 0 ]; then
        local after_hash=$(git rev-parse HEAD 2>&1 || echo "")
        print_info "    拉取后提交: ${after_hash:0:8}"
        
        if [ "$before_hash" != "$after_hash" ] && [ -n "$before_hash" ] && [ -n "$after_hash" ]; then
            print_success "    仓库已更新（从 ${before_hash:0:8} 到 ${after_hash:0:8}）"
        else
            print_info "    仓库已是最新（无新提交）"
        fi
        if [ "$is_retry" = "true" ]; then
            echo "✓ 成功（重试，耗时 ${pull_duration}秒）" >&2
        else
            echo "✓ 成功（耗时 ${pull_duration}秒）" >&2
        fi
        cd "$original_dir" || true
        return 0
    else
        # 第一层重试：如果失败且不是重试，立即重试一次
        if [ "$is_retry" != "true" ]; then
            echo "" >&2
            print_warning "  更新失败，立即重试一次..."
            cd "$original_dir" || true
            sleep 1
            update_repo "$repo" "$repo_path" "$group_folder" "$current_index" "$total_sync" "true" "$error_log_ref"
            return $?
        else
            echo "✗ 失败（耗时 ${pull_duration}秒）" >&2
            # 错误信息已经在终端显示了，这里只记录基本错误
            local error_msg="${pull_output:-拉取失败，退出代码: $pull_exit_code}"
            print_error "  拉取失败: $error_msg"
            print_error "  请查看上方的错误信息"
            # 记录失败日志
            if [ -n "$error_log_ref" ]; then
                # 使用 nameref 安全地添加元素
                local -n error_log_array=$error_log_ref
                error_log_array+=("$repo|更新失败|$error_msg")
            fi
            cd "$original_dir" || true
            return 1
        fi
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
    print_operation_start "检查本地仓库状态" "$repo_path"
    if [ -d "$repo_path" ]; then
        # 检查是否是 git 仓库
        if [ -d "$repo_path/.git" ]; then
            print_operation_end "检查本地仓库状态" "success" "0" "已存在 git 仓库"
            print_info "  检测到已存在的 git 仓库，执行更新操作"
            update_repo "$repo" "$repo_path" "$group_folder" "$current_index" "$total_sync" "false" "$error_log_ref"
            return $?
        else
            print_operation_end "检查本地仓库状态" "warning" "0" "目录存在但不是 git 仓库"
            echo "[$current_index/$total_sync] [跳过] $repo - 目录已存在但不是 git 仓库" >&2
            print_warning "  目录 $repo_path 存在但不是 git 仓库，跳过同步"
            print_warning "  如需同步此仓库，请先删除或重命名该目录"
            if [ -n "$error_log_ref" ]; then
                # 使用 nameref 安全地添加元素
                local -n error_log_array=$error_log_ref
                error_log_array+=("$repo|跳过|目录已存在但不是 git 仓库")
            fi
            return 2
        fi
    else
        print_operation_end "检查本地仓库状态" "success" "0" "新仓库，需要克隆"
        print_info "  检测到新仓库，执行克隆操作"
        clone_repo "$repo" "$repo_path" "$current_index" "$total_sync" "false" "$error_log_ref"
        return $?
    fi
}

