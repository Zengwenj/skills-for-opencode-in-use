# Windows 配置指南

## 环境变量配置

Vault 路径已自动设置为: `D:\ObsBocdVault`（示例/当前配置）

如需修改，运行以下 PowerShell 命令：

```powershell
[Environment]::SetEnvironmentVariable('OBSIDIAN_VAULT', '你的新路径', 'User')
```

## 使用方式

### 方式 1: PowerShell（推荐）

```powershell
# 基础全文搜索
.\scripts\smart-search.ps1 -Query "工作报告"

# 指定结果数量
.\scripts\smart-search.ps1 -Query "项目进度" -Limit 20

# 指定不同的 vault
.\scripts\smart-search.ps1 -Query "关键词" -VaultPath "C:\其他Vault"
```

### 方式 2: 命令提示符 (CMD)

```cmd
.\scripts\smart-search.bat "工作报告"
```

### 方式 3: Git Bash

```bash
# 使用 bash 脚本
./scripts/smart-search.sh "工作报告"

# 或使用 PowerShell
powershell.exe -File scripts/smart-search.ps1 -Query "工作报告"
```

### 方式 4: 高级语义查询（需要官方 Obsidian CLI）

任务、标签、属性、反链、出链、大纲等结构化查询需要官方 Obsidian CLI 支持：

```powershell
# 查询待办任务
obsidian tasks todo

# 看反向链接
obsidian backlinks file="项目计划"

# 查看标签
obsidian tags

# 查看文档大纲
obsidian outline file="会议纪要"
```

> 高级查询依赖官方 Obsidian CLI。在 Obsidian 中启用：Settings → General → Command line interface。

### 方式 5: OpenCode 中使用

在 OpenCode 中直接说：
```
帮我搜索和"Q3项目"相关的资料
```

AI 会根据意图自动路由到基础搜索或高级语义查询。

## 快捷使用

### 创建快捷别名

**PowerShell:**
```powershell
# 添加到 PowerShell 配置文件
notepad $PROFILE

# 添加以下内容：
function obs-search {
    param([string]$Query, [int]$Limit = 10)
    & "C:\Users\$env:USERNAME\.config\opencode\skills\obsidian-unified-search\scripts\smart-search.ps1" -Query $Query -Limit $Limit
}
```

**CMD:**
```cmd
# 创建 obs-search.bat 放到 PATH 中的目录
@echo off
powershell.exe -ExecutionPolicy Bypass -File "C:\Users\%USERNAME%\.config\opencode\skills\obsidian-unified-search\scripts\smart-search.ps1" -Query %*
```

## 四层基础搜索状态

当前配置（示例：`D:\ObsBocdVault`）：
- **第一层 - Omnisearch HTTP**：需要 Obsidian 运行并启用 HTTP server
- **第二层 - 官方 CLI**：需要 Obsidian 运行并注册 CLI
- **第三层 - obs CLI**：可选备用方案（`npm install -g obsidian-vault-cli`）
- **第四层 - ripgrep / Select-String**：推荐安装用于兜底

> 基础全文搜索走 `smart-search.*` 四层故障转移，高级语义查询走官方 CLI，二者互不替代。

## 故障排除

### 执行策略问题

如果遇到执行策略错误，运行：

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### Obsidian CLI 未找到

手动添加 Obsidian 到 PATH：

```powershell
[Environment]::SetEnvironmentVariable('Path', $env:Path + ';C:\Program Files\Obsidian', 'User')
```

### ripgrep 未安装

```powershell
# 使用 Chocolatey
choco install ripgrep

# 或使用 Scoop
scoop install ripgrep

# 或从 GitHub 下载
# https://github.com/BurntSushi/ripgrep/releases
```

## 下一步

1. 打开 Obsidian
2. 安装 Omnisearch 插件
3. 启用 HTTP server (Settings → Omnisearch → Enable HTTP server)
4. 启用官方 CLI (Settings → General → Command line interface)
5. 测试基础搜索: `.\scripts\smart-search.ps1 -Query "测试"`
6. 测试高级查询: `obsidian tags`
