# obsidian-unified-search — Obsidian 四层故障转移搜索

## 概述

自动选择最佳可用搜索方式的 Obsidian 笔记搜索方案。四层优先级故障转移。

## 搜索层级

| 优先级 | 方案 | 触发条件 | 特点 |
|--------|------|----------|------|
| 1 | Omnisearch HTTP | Obsidian 运行且 HTTP 开启 | 最快，BM25 权重 |
| 2 | 官方 Obsidian CLI | Obsidian 运行但 HTTP 不可用 | 功能最全 |
| 3 | obs CLI (`obsidian-vault-cli`) | Obsidian 未运行 | 独立运行 |
| 4 | ripgrep | 以上都不可用 | 零依赖兜底 |

## 脚本清单

```
scripts/
├── smart-search.sh          ← 主搜索脚本 (Bash)
├── smart-search.ps1         ← 主搜索脚本 (PowerShell)
├── smart-search.bat         ← Windows 批处理入口
├── smart-search-simple.ps1  ← 简化版 PowerShell 搜索
├── check-env.sh             ← 环境依赖检查
└── verify-all.sh            ← 全部方案可用性验证
```

## 使用方式

```bash
# 基础搜索
~/.config/opencode/skills/obsidian-unified-search/scripts/smart-search.sh "工作报告"

# 指定结果数量
smart-search.sh "项目进度" 20

# Windows PowerShell
smart-search.ps1 "工作报告"
```

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `OBSIDIAN_VAULT` | `~/Documents/ObsidianVault` | Vault 路径 |
| `OMNISEARCH_PORT` | `51361` | Omnisearch HTTP 端口 |
| `SEARCH_TIMEOUT` | `3` | 搜索超时（秒） |

## 依赖（至少需要一个）

1. Obsidian 1.12+ + Omnisearch 插件（方案 1-2）
2. `npm install -g obsidian-vault-cli`（方案 3）
3. ripgrep（方案 4，大多数系统已预装）

## 故障排除

```bash
# 检查环境
check-env.sh

# 验证全部方案
verify-all.sh
```

## 平台差异

- Bash 脚本 (`smart-search.sh`) 为主要维护版本
- PowerShell (`smart-search.ps1`) 和 BAT (`smart-search.bat`) 为 Windows 兼容版本
- `smart-search-simple.ps1` 是无外部依赖的简化版
