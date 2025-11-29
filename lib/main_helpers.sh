#!/bin/bash
# 主执行流程辅助函数

# 解析命令行参数
parse_arguments() {
    local args=("$@")
    
    # 处理 -a 或 --all 参数：同步所有分组
    if [ "${args[0]}" = "-a" ] || [ "${args[0]}" = "--all" ]; then
        print_info "将同步所有分组..."
        
        local all_groups=$(get_all_group_names)
        if [ -z "$all_groups" ]; then
            print_error "无法读取分组列表"
            exit 1
        fi
        
        local groups_array=()
        while IFS= read -r group; do
            [ -n "$group" ] && groups_array+=("$group")
        done <<< "$all_groups"
        
        if [ ${#groups_array[@]} -eq 0 ]; then
            print_error "配置文件中没有找到任何分组"
            exit 1
        fi
        
        print_info "找到 ${#groups_array[@]} 个分组"
        printf '%s\n' "${groups_array[@]}"
        return 0
    fi
    
    # 返回原始参数
    printf '%s\n' "${args[@]}"
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

# 构建同步仓库映射（用于清理检查）
build_sync_repos_map() {
    local -n sync_repos_map_ref=$1
    
    for group_folder in "${!group_folders[@]}"; do
        if [ -d "$group_folder" ]; then
            # 使用 nullglob 处理空目录情况
            shopt -s nullglob
            for dir in "$group_folder"/*; do
                if [ -d "$dir" ] && [ -d "$dir/.git" ]; then
                    local repo_name=$(basename "$dir")
                    sync_repos_map_ref["$group_folder/$repo_name"]=1
                fi
            done
            shopt -u nullglob
        fi
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
    local repos_array=()
    while IFS= read -r repo_name; do
        [ -n "$repo_name" ] && repos_array+=("$repo_name")
    done <<< "$group_repos"
    
    local total_count=${#repos_array[@]}
    local current_index=0
    
    # 记录失败的仓库（用于第二层重试）
    local failed_repos=()
    
    print_step "开始同步分组 '$group_name'（共 $total_count 个仓库）..."
    print_info "分组文件夹: $group_folder"
    echo "" >&2
    
    # 遍历数组而不是重新读取字符串
    for repo_name in "${repos_array[@]}"; do
        
        if [ -z "$repo_name" ]; then
            continue
        fi
        
        ((current_index++))
        
        echo "" >&2
        print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        print_info "处理仓库 [$current_index/$total_count]: $repo_name"
        print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # 查找仓库完整名称
        print_operation_start "查找仓库完整名称" "$repo_name"
        local start_time=$(date +%s)
        local repo_full=$(find_repo_full_name "$repo_name")
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        if [ -z "$repo_full" ]; then
            print_operation_end "查找仓库完整名称" "fail" "$duration" "未找到远程仓库"
            echo "[$current_index/$total_count] [错误] $repo_name - 远程仓库不存在" >&2
            print_error "    未找到远程仓库: $repo_name"
            print_error "    可能原因: 仓库已被删除、仓库名错误、或没有访问权限"
            record_error "$error_log_ref" "$repo_name" "错误" "远程仓库不存在"
            update_sync_statistics "" 1
            continue
        fi
        
        print_operation_end "查找仓库完整名称" "success" "$duration" "$repo_full"
        print_info "    找到远程仓库: $repo_full"
        
        # 同步单个仓库
        print_operation_start "同步仓库" "$repo_full -> $group_folder/$repo_name"
        local sync_start_time=$(date +%s)
        local result
        sync_single_repo "$repo_full" "$repo_name" "$group_folder" "$current_index" "$total_count" "$error_log_ref"
        result=$?
        local sync_end_time=$(date +%s)
        local sync_duration=$((sync_end_time - sync_start_time))
        
        if [ $result -eq 0 ]; then
            print_operation_end "同步仓库" "success" "$sync_duration" "$repo_name"
        elif [ $result -eq 2 ]; then
            print_operation_end "同步仓库" "skip" "$sync_duration" "$repo_name (已跳过)"
        else
            print_operation_end "同步仓库" "fail" "$sync_duration" "$repo_name"
        fi
        
        # 更新统计信息
        local repo_path="$group_folder/$repo_name"
        update_sync_statistics "$repo_path" "$result"
        
        # 记录失败的仓库（用于重试）
        if [ $result -ne 0 ] && [ $result -ne 2 ]; then
            failed_repos+=("$repo_full|$repo_name")
        fi
    done
    
    # 返回失败的仓库列表（用于第二层重试）
    printf '%s\n' "${failed_repos[@]}"
}

# 收集仍然失败的仓库（用于第三层重试）
# 返回值：仍然失败的仓库数量
collect_still_failed_repos() {
    local failed_repos_ref=$1
    local group_folder=$2
    local global_failed_array=$3
    
    # 使用 nameref 获取数组引用
    local -n failed_repos=$failed_repos_ref
    local still_failed=()
    
    # 遍历失败的仓库，检查是否仍然失败
    for failed_repo in "${failed_repos[@]}"; do
        IFS='|' read -r repo_full repo_name <<< "$failed_repo"
        # 检查仓库是否仍然失败
        if [ ! -d "$group_folder/$repo_name/.git" ]; then
            still_failed+=("$repo_full|$repo_name|$group_folder")
        fi
    done
    
    # 将仍然失败的仓库添加到全局数组
    if [ ${#still_failed[@]} -gt 0 ] && [ -n "$global_failed_array" ]; then
        # 使用 nameref 安全地添加元素
        local -n global_array_ref=$global_failed_array
        for repo_info in "${still_failed[@]}"; do
            global_array_ref+=("$repo_info")
        done
    fi
    
    # 返回仍然失败的仓库数量
    echo ${#still_failed[@]}
}

# 同步分组中的仓库（主入口，包含第二层重试）
sync_group_repos() {
    local group_name=$1
    local group_folder=$2
    local group_repos=$3
    local global_failed_array=${4:-""}
    local error_log_ref=${5:-""}
    
    # 同步分组的所有仓库
    local failed_repos_output=$(sync_group_repos_main "$group_name" "$group_folder" "$group_repos" "$error_log_ref")
    
    # 将输出转换为数组
    local failed_repos=()
    while IFS= read -r line; do
        [ -n "$line" ] && failed_repos+=("$line")
    done <<< "$failed_repos_output"
    
    # 第二层重试：分组完成后，重试失败的仓库
    if [ ${#failed_repos[@]} -gt 0 ]; then
        echo "" >&2
        print_step "分组 '$group_name' 同步完成，发现 ${#failed_repos[@]} 个失败的仓库"
        print_info "开始第二层重试（分组级重试）..."
        echo "" >&2
        
        # 声明局部数组变量供 batch_retry_repos 使用
        local failed_repos_array=("${failed_repos[@]}")
        
        batch_retry_repos failed_repos_array "$group_folder" 2 "$error_log_ref"
        local retry_result=$?
        
        # 收集仍然失败的仓库（用于第三层重试）
        # collect_still_failed_repos 会返回仍然失败的仓库数量
        local still_failed_count=$(collect_still_failed_repos failed_repos_array "$group_folder" "$global_failed_array")
        
        # 统计重试结果
        if [ $retry_result -gt 0 ]; then
            print_success "第二层重试成功恢复 $retry_result 个仓库"
        fi
        
        # 显示仍然失败的仓库数量
        if [ $still_failed_count -gt 0 ]; then
            print_warning "仍有 $still_failed_count 个仓库失败，将在第三层重试中处理"
        fi
    else
        print_success "分组 '$group_name' 同步完成，所有仓库同步成功！"
    fi
}

# 执行同步操作（遍历所有分组）
execute_sync() {
    local groups=("$@")
    
    # 记录所有失败的仓库（用于第三层重试）
    declare -ga all_failed_repos=()
    # 记录所有失败的仓库和错误信息（用于最终日志）
    declare -ga all_failed_logs=()
    
    # 遍历每个分组
    for input_group in "${groups[@]}"; do
        print_info "处理分组输入: '$input_group'"
        print_operation_start "查找分组" "输入: $input_group"
        local start_time=$(date +%s)
        local group_name=$(find_group_name "$input_group")
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        if [ -z "$group_name" ]; then
            print_operation_end "查找分组" "fail" "$duration" "未找到分组: $input_group"
            print_error "未找到分组: $input_group"
            print_info "使用 --list 查看所有可用分组和代号"
            print_warning "跳过该分组，继续处理其他分组..."
            continue
        fi
        
        print_operation_end "查找分组" "success" "$duration" "找到: $group_name"
        print_success "找到分组: '$group_name'"
        
        print_operation_start "获取分组文件夹" "$group_name"
        local start_time=$(date +%s)
        local group_folder=$(get_group_folder "$group_name")
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        print_operation_end "获取分组文件夹" "success" "$duration" "$group_folder"
        
        print_operation_start "获取分组仓库列表" "$group_name"
        local start_time=$(date +%s)
        local group_repos=$(get_group_repos "$group_name")
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        if [ -z "$group_repos" ]; then
            print_operation_end "获取分组仓库列表" "fail" "$duration" "分组中没有仓库"
            print_warning "分组 $group_name 中没有仓库"
            continue
        fi
        
        local repo_count=$(echo "$group_repos" | grep -c . || echo 0)
        print_operation_end "获取分组仓库列表" "success" "$duration" "共 $repo_count 个仓库"
        
        echo ""
        print_info "将同步分组: $group_name"
        echo ""
        
        # 同步这个分组的所有仓库
        sync_group_repos "$group_name" "$group_folder" "$group_repos" "all_failed_repos" "all_failed_logs"
    done
    
    # 第三层重试：所有分组完成后，统一重试所有失败的仓库
    if [ ${#all_failed_repos[@]} -gt 0 ]; then
        echo ""
        echo "=================================================="
        print_info "所有分组同步完成，发现 ${#all_failed_repos[@]} 个失败的仓库，进行第三层重试..."
        echo "=================================================="
        echo ""
        
        local retry_index=0
        local retry_success_count=0
        for failed_repo in "${all_failed_repos[@]}"; do
            IFS='|' read -r repo_full repo_name group_folder <<< "$failed_repo"
            ((retry_index++))
            
            if retry_repo_sync "$repo_full" "$repo_name" "$group_folder" 3 "${#all_failed_repos[@]}" "$retry_index" "all_failed_logs"; then
                ((retry_success_count++))
            fi
        done
        
        # 更新失败统计（重试成功的应该从失败计数中减去）
        # 注意：retry_repo_sync 内部已经调用了 update_sync_statistics 来增加成功计数
        # 但第一次失败时已经统计为失败，所以需要减少失败计数
        if [ $retry_success_count -gt 0 ]; then
            SYNC_STATS_FAIL=$((SYNC_STATS_FAIL - retry_success_count))
            print_success "第三层重试成功恢复 $retry_success_count 个仓库"
        fi
        
        local final_failed_count=$((${#all_failed_repos[@]} - retry_success_count))
        echo ""
        if [ $final_failed_count -gt 0 ]; then
            print_warning "第三层重试完成，仍有 $final_failed_count 个仓库失败"
        else
            print_success "第三层重试完成，所有仓库已成功同步"
        fi
        echo ""
    fi
    
    # 保存错误日志数组名供后续使用
    declare -g ALL_FAILED_LOGS_ARRAY=all_failed_logs
}

