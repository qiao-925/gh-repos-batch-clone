#!/usr/bin/env python3
# GitHub 仓库批量克隆脚本：极简设计，专注于核心功能
#
# 主要功能：
#   - 解析命令行参数（-t 并行任务数，-c 并行传输数）
#   - 读取并解析 REPO-GROUPS.md 配置文件
#   - 并行批量克隆所有仓库
#   - 克隆后自动检查仓库完整性（git fsck）
#   - 输出最终统计报告
#
# 执行流程：
#   1. 解析命令行参数
#   2. 加载配置文件
#   3. 构建克隆任务列表
#   4. 并行执行克隆
#   5. 克隆完成后统一检查所有成功克隆的仓库
#   6. 输出统计报告
#
# 特性：
#   - 双重并行：应用层并行（-t） + Git 层并行传输（-c）
#   - 直接覆盖：不检查仓库是否存在，直接克隆
#   - 完整性检查：克隆后自动使用 git fsck 验证仓库完整性

import sys
import time
from pathlib import Path
from typing import List, Dict

from lib.args import parse_args
from lib.check import check_repos_parallel
from lib.config import parse_repo_groups, CONFIG_FILE, REPO_OWNER
from lib.failed_repos import save_failed_repos
from lib.logger import log_error, log_info, log_success, log_warning
from lib.parallel import execute_parallel_clone
from lib.paths import SCRIPT_DIR


# 失败列表文件路径
FAILED_REPOS_FILE = SCRIPT_DIR / "failed-repos.txt"


def print_summary(
    total_repos: int,
    success_count: int,
    fail_count: int,
    start_time: float
) -> None:
    """输出最终统计
    
    Args:
        total_repos: 总仓库数
        success_count: 成功数
        fail_count: 失败数
        start_time: 开始时间（Unix 时间戳）
    """
    end_time = time.time()
    duration = int(end_time - start_time)
    
    hours = duration // 3600
    minutes = (duration % 3600) // 60
    seconds = duration % 60
    
    print()
    log_info("========== 克隆完成 ==========")
    log_info(f"总仓库数: {total_repos}")
    log_success(f"成功: {success_count}")
    
    if fail_count > 0:
        log_error(f"失败: {fail_count}")
    else:
        log_info(f"失败: {fail_count}")
    
    log_info(f"耗时: {hours}小时 {minutes}分钟 {seconds}秒")
    log_info("==============================")


def main() -> int:
    """主函数
    
    Returns:
        退出码（0 成功，1 失败）
    """
    # 解析命令行参数（如果显示帮助信息，会在这里退出）
    args = parse_args()
    
    log_info("GitHub 仓库批量克隆脚本启动")
    
    # 记录开始时间
    start_time = time.time()
    
    # 获取任务列表
    if args.file:
        # 从指定文件读取任务列表（统一用 parse_repo_groups 解析 REPO-GROUPS.md 格式）
        log_info(f"从文件读取任务列表: {args.file}")
        tasks = parse_repo_groups(args.file)
    else:
        # 默认从配置文件解析
        log_info(f"解析配置文件: {CONFIG_FILE}")
        tasks = parse_repo_groups()
    
    if not tasks:
        log_error("未找到任何仓库任务")
        return 1
    
    total_repos = len(tasks)
    log_info(f"找到 {total_repos} 个仓库任务")
    
    # 每次执行开始时，先清空失败列表文件
    if FAILED_REPOS_FILE.exists():
        try:
            FAILED_REPOS_FILE.unlink()
        except Exception:
            pass  # 忽略删除失败
    
    # 根据命令执行不同逻辑
    command = args.command if hasattr(args, 'command') and args.command else 'clone'
    
    if command == 'check':
        # check 命令：只检查模式
        log_info("检查模式：检查已存在的仓库")
        success_count, fail_count, failed_tasks = check_repos_parallel(
            tasks,
            parallel_tasks=args.tasks,
            timeout=30
        )
        
        # 保存失败列表
        if failed_tasks:
            save_failed_repos(failed_tasks, FAILED_REPOS_FILE, REPO_OWNER or "qiao-925")
        
        # 输出统计
        print_summary(total_repos, success_count, fail_count, start_time)
        return 1 if fail_count > 0 else 0
    
    elif command == 'clone':
        # clone 命令：正常克隆流程
        # 确保 connections 参数存在（向后兼容）
        connections = getattr(args, 'connections', 8)
        
        success_count, fail_count, failed_tasks = execute_parallel_clone(
            tasks,
            args.tasks,
            connections
        )
        
        # 方案2：所有克隆完成后统一检查
        if success_count > 0:
            log_info("开始检查克隆成功的仓库...")
            
            # 获取所有成功克隆的仓库任务（排除克隆失败的）
            successful_tasks = [
                task for task in tasks 
                if task not in failed_tasks
            ]
            
            # 并行检查所有成功克隆的仓库
            check_success, check_fail, check_failed_tasks = check_repos_parallel(
                successful_tasks,
                parallel_tasks=args.tasks,
                timeout=30
            )
            
            # 将检查失败的仓库也加入失败列表
            if check_failed_tasks:
                log_warning(f"发现 {len(check_failed_tasks)} 个仓库检查失败")
                failed_tasks.extend(check_failed_tasks)
                fail_count += len(check_failed_tasks)
                success_count -= len(check_failed_tasks)
        
        # 保存失败列表（如果有失败的仓库）
        if failed_tasks:
            save_failed_repos(failed_tasks, FAILED_REPOS_FILE, REPO_OWNER or "qiao-925")
        
        # 输出统计
        print_summary(total_repos, success_count, fail_count, start_time)
        
        # 返回退出码
        return 1 if fail_count > 0 else 0
    else:
        log_error(f"未知命令: {command}")
        return 1


if __name__ == '__main__':
    sys.exit(main())

