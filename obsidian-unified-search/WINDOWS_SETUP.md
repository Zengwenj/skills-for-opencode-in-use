# Windows 配置指南

## 环境变量配置

Vault 路径已自动设置为: `D:\ObsBocdVault`

如需修改，运行以下 PowerShell 命令：

```powershell
[Environment]::SetEnvironmentVariable('OBSIDIAN_VAULT', '你的新路径', 'User')
```

## 使用方式

### 方式 1: PowerShell（推荐）

```powershell
# 直接运行
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

### 方式 4: OpenCode 中使用

在 OpenCode 中直接说：
```
帮我搜索和"Q3项目"相关的资料
```

AI 会自动调用最佳可用方案并返回结果。

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

## 三层方案状态

当前配置：
- ✅ **Vault 路径**: D:\ObsBocdVault
- ⚠️ **Omnisearch HTTP**: 需要 Obsidian 运行并启用 HTTP server
- ⚠️ **官方 CLI**: 需要 Obsidian 运行并注册 CLI
- ⚠️ **obs CLI**: 可选备用方案
- ⚠️ **ripgrep**: 推荐安装用于兜底

## 下一步

1. 打开 Obsidian
2. 安装 Omnisearch 插件
3. 启用 HTTP server (Settings → Omnisearch → Enable HTTP server)
4. 测试搜索: `.\scripts\smart-search.ps1 -Query "测试"`
