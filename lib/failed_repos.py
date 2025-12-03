# 失败列表生成模块
#
# 主要功能：
#   - save_failed_repos()：保存失败的仓库列表为 REPO-GROUPS.md 格式

import re
from collections import defaultdict
from pathlib import Path
from typing import Dict, List

from lib.config import REPO_OWNER
from lib.logger import log_info, log_warning
from lib.paths import SCRIPT_DIR


def extract_highland_from_folder(group_folder: str) -> str:
    """从 group_folder 中提取高地编号
    
    Args:
        group_folder: 分组文件夹路径（格式：组名 (高地编号)）
    
    Returns:
        高地编号（如果存在），否则返回空字符串
    """
    # 正则表达式：匹配 (高地编号) 格式
    pattern = r'\(([^)]+)\)'
    match = re.search(pattern, group_folder)
    if match:
        return match.group(1).strip()
    return ''


def save_failed_repos(
    failed_tasks: List[Dict[str, str]],
    failed_repos_file: Path,
    repo_owner: str
) -> None:
    """保存失败的仓库列表为 REPO-GROUPS.md 格式
    
    Args:
        failed_tasks: 失败的任务列表
        failed_repos_file: 失败列表文件路径
        repo_owner: 仓库所有者
    
    Note:
        如果 failed_tasks 为空，不会创建文件（文件应该已经在执行开始时被清空）
    """
    if not failed_tasks:
        # 如果没有失败任务，确保文件不存在
        if failed_repos_file.exists():
            try:
                failed_repos_file.unlink()
            except Exception:
                pass  # 忽略删除失败
        return
    
    # 按分组组织失败的仓库
    group_repos: Dict[str, List[str]] = defaultdict(list)  # {group_name: [repo_name, ...]}
    group_highlands: Dict[str, str] = {}  # {group_name: highland}
    
    for task in failed_tasks:
        group_name = task['group_name']
        repo_name = task['repo_name']
        
        # 优先使用任务中的 highland，否则从 group_folder 中提取
        highland = task.get('highland', '')
        if not highland:
            highland = extract_highland_from_folder(task['group_folder'])
        
        group_repos[group_name].append(repo_name)
        if group_name not in group_highlands:
            group_highlands[group_name] = highland
    
    # 生成文件内容
    lines = [
        "# GitHub 仓库分组",
        "",
        f"仓库所有者: {repo_owner}",
        ""
    ]
    
    # 按分组名排序输出
    for group_name in sorted(group_repos.keys()):
        highland = group_highlands.get(group_name, '')
        repos = group_repos[group_name]
        
        # 输出分组标题
        if highland:
            lines.append(f"## {group_name} <!-- {highland} -->")
        else:
            lines.append(f"## {group_name}")
        
        # 输出仓库列表
        for repo in repos:
            if repo:  # 确保仓库名不为空
                lines.append(f"- {repo}")
        lines.append("")
    
    # 写入文件
    try:
        failed_repos_file.write_text('\n'.join(lines), encoding='utf-8')
        
        log_warning(f"有 {len(failed_tasks)} 个仓库克隆失败")
        log_info(f"失败列表已保存到: {failed_repos_file}（REPO-GROUPS.md 格式）")
        log_info(f"可以使用以下命令重新执行失败的仓库:")
        log_info(f"  repos clone -f {failed_repos_file}")
    except Exception as e:
        log_warning(f"保存失败列表失败: {failed_repos_file} - {e}")

