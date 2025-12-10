# GitHub 仓库分类 Prompt

## 功能

自动获取 GitHub 仓库列表并分类，支持**全量生成**和**增量更新**两种模式。

## 使用方法

```
@GitHub 仓库分类 Prompt.md 执行仓库分类
```

## 执行步骤（AI Agent 必须严格按此执行）

### 1. 检测模式
- 检查 `REPO-GROUPS.md` 是否存在
- **不存在** → 全量生成模式
- **存在** → 增量更新模式

### 2. 获取仓库列表
```bash
# 获取用户名（如果 REPO-GROUPS.md 存在，从文件中读取"仓库所有者: xxx"）
# 如果不存在，使用：gh api user --jq .login

# 获取所有仓库
gh repo list [用户名] --limit 1000 --json name --jq '.[].name'
```

### 3. 处理仓库

**全量生成模式**：
1. 获取所有仓库列表
2. 直接生成完整的 `REPO-GROUPS.md`，按以下分组分类：
   - Go-Practice（包含 go、golang、gin、gitea 等关键词）
   - Java-Practice（包含 java、spring、elasticsearch、drools、seata、rocketmq 等关键词）
   - AI-Practice（包含 ai、rag、llm、llamaindex、ocr、mcp、systematology 等关键词）
   - Tools（包含 tool、gh-repos、get_jobs、hugo、mattermost 等关键词）
   - Daily（包含 resume、inspiration、assemble 等关键词）
3. 格式：`## 分组名 <!-- 标签 -->`（标签：小火龙、杰尼龟、皮卡丘、可达鸭、妙蛙种子）
4. **直接生成文件，展示预览，等待用户确认**

**增量更新模式**：
1. 读取现有 `REPO-GROUPS.md`，提取所有已存在的仓库名（匹配 `^- \S+$`）
2. 获取 GitHub 上的所有仓库列表
3. **对比分析**：
   - 找出**新增仓库**（在 GitHub 上但不在 REPO-GROUPS.md 中）
   - 找出**已删除仓库**（在 REPO-GROUPS.md 中但不在 GitHub 上）
4. **处理新增仓库**（如果有）：
   - 将新仓库**直接追加到文件末尾**（格式：`## 分组名\n- 仓库名`）
   - 按关键词自动分类到对应分组
   - **展示新增仓库列表和分类建议**
5. **处理已删除仓库**（如果有）：
   - **必须告知用户哪些仓库已删除**
   - 询问用户是否要从 REPO-GROUPS.md 中移除这些仓库
   - 如果用户确认，从对应分组中删除这些仓库条目
6. **展示完整报告**：
   - 新增仓库列表（如有）
   - 已删除仓库列表（如有）
   - **等待用户确认后保存**
7. **如果既没有新增也没有删除**：提示"仓库列表无变化，无需更新"

## 重要要求

1. **不要创建临时脚本**：直接使用 `gh repo list` 命令，不要写 Python 脚本
2. **增量更新时保留原有内容**：所有原有仓库、分组、标签都要保留
3. **新仓库追加到文件末尾**：不要修改现有分组，新仓库追加到文件末尾即可
4. **用户确认后才保存**：展示预览，用户确认后再写入文件

## 分类规则

根据仓库名称关键词自动分类：
- **Go-Practice**：go、golang、gin、gitea
- **Java-Practice**：java、spring、elasticsearch、drools、seata、rocketmq、xxl-job、hutool、hippo4j
- **AI-Practice**：ai、rag、llm、llamaindex、ocr、mcp、systematology
- **Tools**：tool、gh-repos、get_jobs、hugo、mattermost、geekgeekrun、examples
- **Daily**：resume、inspiration、assemble、qiao-925

## 文件格式

```markdown
# GitHub 仓库分组

仓库所有者: qiao-925

## Go-Practice <!-- 小火龙 -->
- 仓库名1
- 仓库名2

## Java-Practice <!-- 杰尼龟 -->
- 仓库名1
- 仓库名2
```

## 错误处理

- GitHub CLI 未安装：提示用户安装 `gh` 并执行 `gh auth login`
- GitHub CLI 未登录：提示用户执行 `gh auth login`
- 其他错误：显示错误信息，不要继续执行
