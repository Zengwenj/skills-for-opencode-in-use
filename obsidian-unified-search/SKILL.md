# Obsidian 统一搜索

三层混合智能搜索方案，自动选择最佳可用搜索方式，确保随时随地都能找到笔记。

## 概述

本 Skill 实现了三层故障转移搜索架构：

1. **主方案**: Omnisearch HTTP (速度最快，BM25 权重)
2. **备用方案**: 官方 Obsidian CLI (功能完整)
3. **离线方案**: obs 社区 CLI (独立运行)
4. **应急方案**: ripgrep (零依赖兜底)

## 安装依赖

### 必需（至少一个）

```bash
# 方案 1-2: Obsidian 官方工具
# - 安装 Obsidian 1.12+
# - 启用 CLI: Settings → General → Command line interface
# - 安装 Omnisearch 插件并启用 HTTP server

# 方案 3: 社区 CLI (推荐安装作为备用)
npm install -g obsidian-vault-cli
obs init  # 配置 vault

# 方案 4: ripgrep (大多数系统已预装)
# macOS: brew install ripgrep
# Ubuntu: sudo apt install ripgrep
# Windows: choco install ripgrep
```

## 快速开始

### 方式 1: 直接运行脚本

```bash
# 基础搜索
~/.config/opencode/skills/obsidian-unified-search/scripts/smart-search.sh "工作报告"

# 指定结果数量
~/.config/opencode/skills/obsidian-unified-search/scripts/smart-search.sh "项目进度" 20
```

### 方式 2: OpenCode 中使用

在 OpenCode 中直接说：

```
帮我搜索和"Q3项目"相关的资料
```

AI 会自动调用智能搜索并返回结果。

## 搜索优先级

系统按以下顺序尝试，使用第一个可用的方案：

| 优先级 | 方案 | 触发条件 | 特点 |
|--------|------|----------|------|
| 1 | Omnisearch HTTP | Obsidian 运行且 HTTP 开启 | 速度最快，有 BM25 权重 |
| 2 | 官方 CLI | Obsidian 运行但 HTTP 不可用 | 功能最全，支持复杂查询 |
| 3 | obs CLI | Obsidian 未运行 | 独立运行，随时可用 |
| 4 | ripgrep | 以上都不可用 | 零依赖，纯文本搜索 |

## 环境变量

```bash
# Vault 路径（默认为 ~/Documents/ObsidianVault）
export OBSIDIAN_VAULT="/path/to/your/vault"

# Omnisearch HTTP 端口（默认 51361）
export OMNISEARCH_PORT="51361"

# 搜索超时时间（默认 3 秒）
export SEARCH_TIMEOUT="3"
```

## 使用场景

### 场景 1: 编写工作报告时查找素材

```
用户: 帮我找找和"客户反馈"相关的资料

AI 执行:
1. 检测环境 → Omnisearch HTTP 可用
2. 搜索 → curl http://localhost:51361/search?q=客户反馈
3. 返回:
   📄 meetings/client-feedback.md
      相关度: 0.95
      摘要: 客户反馈总结：主要关注点包括...

   📄 notes/user-research.md
      相关度: 0.87
      摘要: 用户调研发现的关键反馈...
4. 建议: "第1条适合放入'问题总结'部分，第2条有具体数据..."
```

### 场景 2: Obsidian 未运行时的紧急查找

```
用户: 搜索"合同条款"

AI 执行:
1. 检测 → Omnisearch 和官方 CLI 都不可用
2. 降级 → obs search content "合同条款"
3. 返回: 离线搜索结果
4. 提示: "Obsidian 未运行，显示离线搜索结果"
```

### 场景 3: 批量处理搜索结果

```bash
# 导出所有匹配的文件列表
~/.config/opencode/skills/obsidian-unified-search/scripts/smart-search.sh "TODO" 50 | \
  grep "^📄" | sed 's/📄 //' > todo-files.txt

# 统计标签分布（需要 obs CLI）
obs tags all --sort count --limit 20
```

## 故障排除

### 问题 1: 所有方案都不可用

```bash
# 运行验证脚本
~/.config/opencode/skills/obsidian-unified-search/scripts/check-env.sh
```

### 问题 2: Omnisearch HTTP 连接失败

```bash
# 检查端口
curl -v http://localhost:51361/search?q=test

# 检查 Obsidian 设置
# 1. 确保 Omnisearch 插件已启用
# 2. 确保 HTTP server 已开启
# 3. 检查防火墙是否阻止 51361 端口
```

### 问题 3: 官方 CLI 未找到

```bash
# macOS: 手动添加 PATH
export PATH="$PATH:/Applications/Obsidian.app/Contents/MacOS"

# Linux (AppImage):
export PATH="$PATH:/path/to/obsidian.AppImage"

# Windows: 已自动添加，检查环境变量
```

### 问题 4: obs CLI 找不到 vault

```bash
# 重新配置
obs init
# 或手动指定
obs vault config defaultVault /path/to/vault
```

## 高级用法

### 自定义搜索模板

创建 `~/.config/opencode/skills/obsidian-unified-search/templates/work-report.md`：

```markdown
# 工作报告素材模板

搜索主题: {{query}}
搜索时间: {{date}}

## 搜索结果

{{results}}

## 建议结构

1. 背景介绍
2. 关键数据
3. 问题分析
4. 下一步计划
```

### 结合 AI 自动整理

```bash
# 搜索并生成总结
~/.config/opencode/skills/obsidian-unified-search/scripts/smart-search.sh "Q3进度" | \
  tee /tmp/search-results.txt | \
  opencode --ask "请整理这些素材，生成工作报告的提纲"
```

## 性能优化

### 加速搜索

```bash
# 使用更快的超时
timeout 1 command...

# 限制结果数量
--limit 5

# 使用 ripgrep 的并行搜索
rg --threads 8 ...
```

### 缓存结果

```bash
# 缓存最近搜索结果
CACHE_DIR="$HOME/.cache/obsidian-search"
mkdir -p "$CACHE_DIR"

# 检查缓存
CACHE_FILE="$CACHE_DIR/$(echo "$QUERY" | md5sum | cut -d' ' -f1).json"
if [ -f "$CACHE_FILE" ] && [ $(($(date +%s) - $(stat -c %Y "$CACHE_FILE"))) -lt 300 ]; then
    cat "$CACHE_FILE"
else
    smart-search.sh "$QUERY" > "$CACHE_FILE"
fi
```

## 相关链接

- [Obsidian CLI 文档](https://help.obsidian.md/cli)
- [obs CLI 仓库](https://github.com/markfive-proto/obsidian-vault-cli)
- [Omnisearch 插件](https://github.com/scambier/obsidian-omnisearch)

## 许可证

MIT
