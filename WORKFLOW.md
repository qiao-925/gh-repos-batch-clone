# sync-groups-v2.sh 工作流与架构文档

---

## 整体架构

### 架构层次

```
┌─────────────────────────────────────────────────────────┐
│                    主函数入口 (main)                      │
│  ┌───────────────────────────────────────────────────┐  │
│  │  1. 初始化环境 (initialize_sync)                   │  │
│  │  2. 初始化缓存系统                                 │  │
│  │  3. 全局差异扫描 (scan_global_diff)                │  │
│  │  4. 执行同步 (execute_sync)                        │  │
│  │  5. 清理已删除仓库 (cleanup_deleted_repos)         │  │
│  │  6. 生成统计报告                                   │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
         │
         ├─── 配置解析层
         │    ├── init_config_cache()
         │    ├── get_group_repos()
         │    └── find_group_name()
         │
         ├─── 缓存管理层
         │    ├── REPO_FULL_NAME_CACHE (仓库名映射)
         │    ├── GROUP_REPOS_CACHE (分组仓库列表)
         │    ├── LOCAL_REPOS_CACHE (本地仓库列表)
         │    └── GROUP_HIGHLAND_CACHE (高地编号)
         │
         ├─── GitHub API 层
         │    ├── get_repo_info()
         │    ├── find_repo_full_name()
         │    └── init_repo_cache()
         │
         ├─── 仓库操作层
         │    ├── clone_repo()
         │    ├── update_repo()
         │    └── sync_single_repo()
         │
         └─── 日志与统计层
              ├── print_*() 系列函数
              ├── update_sync_statistics()
              └── compare_remote_local_diff()
```

### 核心设计原则

1. **缓存优先**: 所有数据一次性加载到内存，避免重复 I/O 和 API 调用
2. **优先级处理**: 缺失的仓库优先克隆，已存在的仓库后更新
3. **错误隔离**: 单个仓库失败不影响整体流程，统一收集后重试
4. **状态追踪**: 完整的统计信息和差异分析

---

## 主要工作流程

### 完整执行流程

```
开始
  │
  ├─→ [1] 初始化阶段
  │     ├─ initialize_sync()
  │     │   ├─ 检查配置文件存在性
  │     │   ├─ 初始化 GitHub 连接
  │     │   └─ 初始化统计变量
  │     │
  │     ├─ init_config_cache()
  │     │   └─ 解析 REPO-GROUPS.md，建立分组缓存
  │     │
  │     ├─ init_repo_cache()
  │     │   └─ 批量获取所有远程仓库，建立名称映射
  │     │
  │     └─ list_groups()
  │         └─ 显示所有可用分组（带高地编号）
  │
  ├─→ [2] 差异扫描阶段
  │     └─ scan_global_diff()
  │         ├─ 遍历所有分组和仓库
  │         ├─ 检查每个仓库的本地状态
  │         ├─ 分类：缺失 / 已存在 / 跳过 / 不存在
  │         └─ 存储到全局数组：
  │             ├─ global_repos_to_clone (缺失的)
  │             └─ global_repos_to_update (已存在的)
  │
  ├─→ [3] 本地仓库缓存初始化
  │     └─ init_local_repo_cache()
  │         └─ 扫描所有分组文件夹，建立本地仓库映射
  │
  ├─→ [4] 同步执行阶段（优先级处理）
  │     └─ execute_sync()
  │         │
  │         ├─→ [4.1] 优先处理缺失仓库（克隆）
  │         │     ├─ 遍历 global_repos_to_clone
  │         │     ├─ 对每个仓库调用 clone_repo()
  │         │     └─ 记录失败的仓库到 all_failed_repos
  │         │
  │         ├─→ [4.2] 处理已存在仓库（更新）
  │         │     ├─ 遍历 global_repos_to_update
  │         │     ├─ 对每个仓库调用 update_repo()
  │         │     └─ 记录失败的仓库到 all_failed_repos
  │         │
  │         └─→ [4.3] 统一重试失败的仓库
  │               ├─ 遍历 all_failed_repos
  │               ├─ 调用 retry_repo_sync()
  │               └─ 更新统计信息
  │
  ├─→ [5] 清理阶段
  │     └─ cleanup_deleted_repos()
  │         ├─ 扫描所有本地仓库
  │         ├─ 检查是否在同步列表中
  │         ├─ 检查远程是否还存在
  │         └─ 删除远程已不存在的本地仓库
  │
  └─→ [6] 报告生成阶段
        ├─ print_final_summary()
        ├─ print_failed_repos_details()
        └─ compare_remote_local_diff()
```
嗯