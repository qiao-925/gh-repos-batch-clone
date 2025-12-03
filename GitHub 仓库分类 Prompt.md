# GitHub 仓库分类 Prompt

## Prompt 模板

```
请根据以下 GitHub 仓库列表，按照合理的逻辑进行分类。

仓库所有者: [你的用户名]
仓库列表:
[仓库列表]

要求：
1. 使用 Markdown 格式
2. 每个分类格式：`## 分组名`
   - 分组名：功能描述（如"Go-Practice"、"Java-Practice"、"AI-Practice"）
3. 分类下使用无序列表列出仓库
4. 分类逻辑：按编程语言、学习阶段、项目类型、用途等
```

## 使用方法

**执行分类**
1. 在 Cursor 中执行：`@GitHub 仓库分类 Prompt.md 执行当前prompt`
2. 检查并调整分类
3. 确认后告诉 AI "保存为 REPO-GROUPS.md"

**可选增强功能**
- 如果需要为分类添加有趣的标签（如宝可梦、奥特曼、军事编号等），可以使用增强 Prompt：`@GitHub 仓库分类增强 Prompt.md`

**同步分组**
```bash
# 批量同步所有分组（推荐）
repos
repos clone

# 查看帮助信息
repos --help
repos clone --help

# 配置并行参数（可选）
repos clone -t 10 -c 16  # 并行任务数 10，并行传输数 16
```

