# Obsidian 统一搜索

🎯 三层混合智能搜索方案 - 自动选择最佳可用方式，确保随时随地都能找到笔记

## 核心特性

- ✅ **三层故障转移**: Omnisearch HTTP → 官方 CLI → obs CLI → ripgrep
- ✅ **自动检测**: 智能选择当前环境下最佳搜索方案
- ✅ **零配置**: 开箱即用，自动适应不同环境
- ✅ **统一接口**: 无论底层使用什么方案，调用方式完全一致
- ✅ **OpenCode 集成**: 完美支持 OpenCode/Claude Code AI 助手

## 快速开始

### 1. 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/your-repo/obsidian-unified-search/main/install.sh | bash
```

或手动安装：

```bash
git clone https://github.com/your-repo/obsidian-unified-search.git ~/.config/opencode/skills/obsidian-unified-search
~/.config/opencode/skills/obsidian-unified-search/install.sh
```

### 2. 检测环境

```bash
~/.config/opencode/skills/obsidian-unified-search/scripts/check-env.sh
```

### 3. 开始使用

```bash
# 命令行
~/.config/opencode/skills/obsidian-unified-search/scripts/smart-search.sh "工作报告"

# 或使用别名（安装时创建）
obs-search "项目进度"

# 在 OpenCode 中
"帮我搜索和 Q3 项目相关的资料"
```

## 三层架构

```
┌─────────────────────────────────────────────────┐
│  第一层: Omnisearch HTTP (推荐)                 │
│  • Obsidian 运行时使用                          │
│  • 速度最快，有 BM25 权重                       │
│  • 支持容错搜索                                 │
├─────────────────────────────────────────────────┤
│  第二层: 官方 Obsidian CLI                      │
│  • Obsidian 运行时使用                          │
│  • 功能完整，支持复杂查询                       │
├─────────────────────────────────────────────────┤
│  第三层: obs 社区 CLI                           │
│  • Obsidian 关闭时使用                          │
│  • 完全独立，随时可用                           │
├─────────────────────────────────────────────────┤
│  兜底: ripgrep                                  │
│  • 零依赖，纯文本搜索                           │
│  • 最后保障                                     │
└─────────────────────────────────────────────────┘
```

## 安装依赖

### 主方案（推荐）

- **Obsidian** 1.12+
- **Omnisearch** 插件（开启 HTTP server）

### 备用方案

```bash
# obs 社区 CLI
npm install -g obsidian-vault-cli
obs init

# ripgrep (大多数系统已预装)
# macOS: brew install ripgrep
# Ubuntu: sudo apt install ripgrep
```

## 使用场景

### 场景 1: 编写工作报告

```
用户: 帮我找找和"客户反馈"相关的资料

AI: 🔍 使用 Omnisearch HTTP 搜索...

📄 meetings/client-feedback.md
   相关度: 0.95
   摘要: 客户反馈总结：主要关注点包括...

📄 notes/user-research.md
   相关度: 0.87
   摘要: 用户调研发现的关键反馈...

建议：第1条适合放入"问题总结"部分，第2条有具体数据...
```

### 场景 2: Obsidian 未运行

```
用户: 搜索"合同条款"

AI: ⚠️ Obsidian 未运行，使用离线搜索 (obs CLI)

📄 legal/contracts.md:45
   内容: 合同条款第3条规定...

📄 notes/agreements.md:12
   内容: 根据合同条款，我们需要...
```

### 场景 3: 批量处理

```bash
# 导出所有 TODO 文件
obs-search "TODO" 100 | grep "^📄" | sed 's/📄 //' > todos.txt

# 统计标签分布
obs tags all --sort count --limit 20
```

## 文件结构

```
~/.config/opencode/skills/obsidian-unified-search/
├── SKILL.md                    # 技能定义文件
├── README.md                   # 本文件
├── install.sh                  # 快速安装脚本
├── scripts/
│   ├── smart-search.sh        # 智能搜索脚本（核心）
│   └── check-env.sh           # 环境检测脚本
└── templates/                  # 搜索模板（可选）
```

## 环境变量

```bash
# Vault 路径（默认: ~/Documents/ObsidianVault）
export OBSIDIAN_VAULT="/path/to/your/vault"

# Omnisearch 端口（默认: 51361）
export OMNISEARCH_PORT="51361"

# 搜索超时（默认: 3 秒）
export SEARCH_TIMEOUT="3"
```

## 故障排除

### 所有方案都不可用

```bash
# 运行环境检测
./scripts/check-env.sh
```

### Omnisearch HTTP 连接失败

1. 确保 Obsidian 正在运行
2. 检查 Omnisearch 设置中 HTTP server 已启用
3. 检查端口 51361 是否被防火墙阻止

### 官方 CLI 未找到

```bash
# macOS
export PATH="$PATH:/Applications/Obsidian.app/Contents/MacOS"

# Linux (AppImage)
export PATH="$PATH:/path/to/obsidian"
```

## 相关项目

- [Obsidian](https://obsidian.md/) - 强大的知识库工具
- [Omnisearch](https://github.com/scambier/obsidian-omnisearch) - Obsidian 搜索插件
- [obsidian-vault-cli](https://github.com/markfive-proto/obsidian-vault-cli) - 社区 CLI 工具
- [kepano/obsidian-skills](https://github.com/kepano/obsidian-skills) - 官方 Obsidian skills

## 许可证

MIT
