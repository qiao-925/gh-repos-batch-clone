# GitHub 仓库管理器

集中管理所有 GitHub 仓库的工具仓库，支持 AI 辅助分组和**按需批量同步**。

## 🎯 核心功能

- 📋 **分组管理**: 手动编辑配置文件，灵活分组
- 🚀 **按需批量同步**: 按分组批量同步仓库，一次可同步多个分组，节省时间和空间

## 🔧 前置要求

**必须安装 GitHub CLI**，这是使用本工具的前提条件：

1. 安装 [GitHub CLI](https://cli.github.com/)
2. 登录认证：
   ```bash
   gh auth login
   ```

## 🚀 使用流程

### 步骤 1：创建分类文档并同步

**在 Cursor 对话框中执行 PROMPT**

1. 打开 `PROMPT.md`，复制 prompt 模板
2. 在 Cursor 对话框中执行：`@PROMPT.md 执行当前prompt`
3. AI 会生成分类文档并展示在对话框中
4. 检查分类是否合理，如需调整告诉 AI 你的修改意见
5. 确认满意后，告诉 AI "保存" 或 "持久化"，AI 会保存为 `REPO-GROUPS.md`

**按需批量同步分组**

完成分类后，选择需要同步的分组进行批量同步：

```bash
# 批量同步单个分组（该分组下的所有仓库）
bash sync-groups-v2.sh 597.9

# 批量同步多个分组（一次同步多个分组的所有仓库）
bash sync-groups-v2.sh 597.9 537.7 54号

# 同步所有分组（按分组clone所有仓库）
bash sync-groups-v2.sh -a

# 列出所有可用分组
bash sync-groups-v2.sh --list
```

💡 **批量同步优势**：一次命令可以同步多个分组，每个分组下的所有仓库会自动批量处理（克隆或更新），大大提高效率。使用 `-a` 参数可以一次性同步所有分组，适合首次设置或完整备份。

**文件夹组织**：每个分组会自动创建对应的文件夹（使用代号作为文件夹名，如 `597.9`、`54号`），该分组下的所有仓库会同步到对应的文件夹中，实现清晰的组织结构。

**单个仓库深克隆**

脚本默认使用浅克隆（`--depth 1`）以节省时间和空间。如果需要对单个仓库进行深克隆（获取完整历史），可以使用以下方法：

```bash
# 方法 1：将现有浅克隆转换为深克隆（推荐）
cd <分组文件夹>/<仓库名>
git fetch --unshallow
git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
git fetch origin

# 方法 2：删除后重新深克隆
rm -rf <分组文件夹>/<仓库名>
git clone https://github.com/<用户名>/<仓库名>.git <分组文件夹>/<仓库名>
```

**示例**：
```bash
# 将 60 分组下的 Assemble 仓库转换为深克隆
cd 60/Assemble
git fetch --unshallow
git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
git fetch origin
```

### 步骤 2：打开分组文件夹作为 Workspace

同步完成后，每个分组都有自己的文件夹，可以直接打开文件夹作为 workspace：

1. **在 VS Code/Cursor 中打开分组文件夹**：
   - 直接打开对应的分组文件夹（如 `597.9`、`54号`）
   - 该文件夹下的所有仓库都会显示在文件资源管理器中
   - 可以方便地在同一分组的不同仓库间切换

2. **示例**：
   ```bash
   # 同步 Go 学习分组
   bash sync-groups-v2.sh 597.9
   
   # 然后在 VS Code/Cursor 中打开 597.9 文件夹
   # 该文件夹下包含所有 Go 学习相关的仓库
   ```

💡 **Workspace 优势**：每个分组文件夹就是一个天然的 workspace，无需额外配置，结构清晰，便于管理嗯