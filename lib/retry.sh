#!/bin/bash
# 重试机制函数

# 通用重试函数
# 参数: repo_full, repo_name, group_folder, retry_level, total_count, current_index, error_log_ref
retry_repo_sync() {
    local repo_full=$1
    local repo_name=$2
    local group_folder=$3
    local retry_level=$4
    local total_count=$5
    local current_index=$6
    local error_log_ref=$7
    
    local level_name=""
    case $retry_level in
        1) level_name="第一层重试" ;;
        2) level_name="第二层重试" ;;
        3) level_name="第三层重试" ;;
        *) level_name="重试" ;;
    esac
    
    echo "" >&2
    print_info "[$level_name $current_index/$total_count] 重试仓库: $repo_name"
    print_info "  完整仓库名: $repo_full"
    print_info "  分组文件夹: $group_folder"
    
    local retry_result
    sync_single_repo "$repo_full" "$repo_name" "$group_folder" "$current_index" "$total_count" "$error_log_ref"
    retry_result=$?
    
    if [ $retry_result -eq 0 ]; then
        # 更新统计信息（sync_single_repo 只返回状态码，不更新统计）
        local repo_path="$group_folder/$repo_name"
        update_sync_statistics "$repo_path" 0
        print_success "  重试成功: $repo_name"
        return 0
    else
        print_error "  重试仍然失败: $repo_name"
        return 1
    fi
}

# 批量重试失败的仓库
batch_retry_repos() {
    local failed_repos_ref=$1
    local group_folder=$2
    local retry_level=$3
    local error_log_ref=$4
    
    # 使用 nameref 获取数组引用
    local -n failed_repos=$failed_repos_ref
    local retry_count=${#failed_repos[@]}
    
    if [ $retry_count -eq 0 ]; then
        return 0
    fi
    
    local retry_index=0
    local retry_success=0
    
    # 遍历失败的仓库
    for failed_repo in "${failed_repos[@]}"; do
        IFS='|' read -r repo_full repo_name <<< "$failed_repo"
        ((retry_index++))
        
        if retry_repo_sync "$repo_full" "$repo_name" "$group_folder" "$retry_level" "$retry_count" "$retry_index" "$error_log_ref"; then
            ((retry_success++))
            # 注意：retry_repo_sync 内部已经调用了 update_sync_statistics 来更新统计
            # 但第一次失败时已经统计为失败，所以需要减少失败计数
            ((SYNC_STATS_FAIL--))
        fi
    done
    
    if [ $retry_success -gt 0 ]; then
        local level_name=""
        case $retry_level in
            1) level_name="第一层" ;;
            2) level_name="第二层" ;;
            3) level_name="第三层" ;;
        esac
        print_success "$level_name重试成功 $retry_success 个仓库"
    fi
    
    return $retry_success
}

