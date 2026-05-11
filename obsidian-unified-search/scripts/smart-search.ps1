# Obsidian 统一搜索 - Windows PowerShell 版本
# 四层基础搜索故障转移方案

param(
    [Parameter(Mandatory=$true)]
    [string]$Query,
    
    [Parameter(Mandatory=$false)]
    [int]$Limit = 10,
    
    [Parameter(Mandatory=$false)]
    [string]$VaultPath = $env:OBSIDIAN_VAULT
)

# 如果未指定 vault 路径，使用默认值
if (-not $VaultPath) {
    $VaultPath = "D:\ObsBocdVault"
}

# Omnisearch HTTP 端口
$OmnisearchPort = if ($env:OMNISEARCH_PORT) { $env:OMNISEARCH_PORT } else { 51361 }

# 超时时间（秒）
$Timeout = if ($env:SEARCH_TIMEOUT) { [int]$env:SEARCH_TIMEOUT } else { 3 }

# 颜色定义
$Colors = @{
    Red = "Red"
    Green = "Green"
    Yellow = "Yellow"
    Blue = "Cyan"
    NC = "White"
}

function Write-ColoredText {
    param(
        [string]$Text,
        [string]$Color = "White"
    )
    Write-Host $Text -ForegroundColor $Color
}

# 检查参数
if (-not $Query) {
    Write-ColoredText "错误: 请提供搜索关键词" $Colors.Red
    Write-ColoredText "用法: .\smart-search.ps1 -Query '关键词' [-Limit 10]" $Colors.Yellow
    exit 1
}

Write-ColoredText "`n🔍 搜索: $Query`n" $Colors.Blue

# 方案 1: Omnisearch HTTP (Obsidian 运行中)
function Try-Omnisearch {
    $endpoint = "http://localhost:$OmnisearchPort/search"
    
    try {
        $testResponse = Invoke-RestMethod -Uri "$endpoint?q=test" -Method GET -TimeoutSec $Timeout -ErrorAction Stop
        
        Write-ColoredText "✓ 使用 Omnisearch HTTP 搜索`n" $Colors.Green
        
        $encodedQuery = [System.Web.HttpUtility]::UrlEncode($Query)
        $result = Invoke-RestMethod -Uri "$endpoint?q=$encodedQuery&limit=$Limit" -Method GET -TimeoutSec $Timeout
        
        if ($result -and $result.Count -gt 0) {
            foreach ($item in $result) {
                Write-ColoredText "📄 $($item.path)" $Colors.Green
                $score = if ($item.score) { $item.score } else { "N/A" }
                Write-ColoredText "   相关度: $score" $Colors.NC
                $excerpt = if ($item.excerpt) { $item.excerpt.Substring(0, [Math]::Min(200, $item.excerpt.Length)) } else { "无摘要" }
                Write-ColoredText "   摘要: $excerpt..." $Colors.NC
                Write-Host ""
            }
            return $true
        }
    }
    catch {
        return $false
    }
    return $false
}

# 方案 2: 官方 CLI (Obsidian 运行中)
function Try-OfficialCli {
    $obsidianCmd = Get-Command obsidian -ErrorAction SilentlyContinue
    
    if ($obsidianCmd) {
        try {
            $testResult = & obsidian search query="test" format=json 2>$null | ConvertFrom-Json -ErrorAction Stop
            
            Write-ColoredText "✓ 使用官方 CLI 搜索`n" $Colors.Green
            
            $resultJson = & obsidian search query="$Query" format=json limit=$Limit 2>$null
            $result = $resultJson | ConvertFrom-Json
            
            if ($result -and $result.Count -gt 0) {
                foreach ($item in $result) {
                    Write-ColoredText "📄 $($item.path)" $Colors.Green
                    $score = if ($item.score) { $item.score } else { "N/A" }
                    Write-ColoredText "   相关度: $score" $Colors.NC
                    $excerpt = if ($item.excerpt) { $item.excerpt.Substring(0, [Math]::Min(200, $item.excerpt.Length)) } else { "无摘要" }
                    Write-ColoredText "   摘要: $excerpt..." $Colors.NC
                    Write-Host ""
                }
                return $true
            }
        }
        catch {
            return $false
        }
    }
    return $false
}

# 方案 3: obs 社区 CLI (独立运行)
function Try-ObsCli {
    $obsCmd = Get-Command obs -ErrorAction SilentlyContinue
    
    if ($obsCmd) {
        Write-ColoredText "⚠ Obsidian 未运行，使用离线搜索 (obs CLI)`n" $Colors.Yellow
        
        try {
            $resultJson = & obs search content "$Query" --limit $Limit --json 2>$null
            $result = $resultJson | ConvertFrom-Json
            
            if ($result -and $result.Count -gt 0) {
                foreach ($item in $result) {
                    Write-ColoredText "📄 $($item.file):$($item.line)" $Colors.Green
                    $content = if ($item.content) { $item.content.Substring(0, [Math]::Min(200, $item.content.Length)) } else { "无内容" }
                    Write-ColoredText "   内容: $content..." $Colors.NC
                    Write-Host ""
                }
                return $true
            }
        }
        catch {
            return $false
        }
    }
    return $false
}

# 方案 4: ripgrep (零依赖兜底)
function Try-Ripgrep {
    $rgCmd = Get-Command rg -ErrorAction SilentlyContinue
    
    if ($rgCmd) {
        Write-ColoredText "⚠ 使用本地 ripgrep 搜索（结果可能不完整）`n" $Colors.Yellow
        
        if (Test-Path $VaultPath) {
            & rg $Query $VaultPath --type md -n --context 2 | Select-Object -First 50 | ForEach-Object {
                Write-ColoredText "📝 $_" $Colors.NC
            }
        }
        else {
            Write-ColoredText "错误: Vault 路径不存在: $VaultPath" $Colors.Red
            Write-ColoredText "请设置 OBSIDIAN_VAULT 环境变量" $Colors.Yellow
        }
        return $true
    }
    elseif (Get-Command Select-String -ErrorAction SilentlyContinue) {
        Write-ColoredText "⚠ 使用 PowerShell Select-String 搜索（较慢）`n" $Colors.Yellow
        
        if (Test-Path $VaultPath) {
            Get-ChildItem -Path $VaultPath -Filter "*.md" -Recurse -ErrorAction SilentlyContinue | 
                Select-String -Pattern $Query | 
                Select-Object -First 50 | 
                ForEach-Object {
                    Write-ColoredText "📝 $($_.Path):$($_.LineNumber) $($_.Line)" $Colors.NC
                }
        }
        return $true
    }
    return $false
}

# 执行搜索（按优先级）
$found = $false

if (Try-Omnisearch) {
    $found = $true
}
elseif (Try-OfficialCli) {
    $found = $true
}
elseif (Try-ObsCli) {
    $found = $true
}
elseif (Try-Ripgrep) {
    $found = $true
}
else {
    Write-ColoredText "`n❌ 错误: 所有搜索方案都不可用" $Colors.Red
    Write-Host ""
    Write-ColoredText "请检查以下事项：" $Colors.Yellow
    Write-ColoredText "1. Obsidian 是否安装并运行" $Colors.NC
    Write-ColoredText "2. Omnisearch 插件是否启用 HTTP server" $Colors.NC
    Write-ColoredText "3. obs CLI 是否安装: npm install -g obsidian-vault-cli" $Colors.NC
    Write-ColoredText "4. ripgrep 是否安装: choco install ripgrep" $Colors.NC
    exit 1
}

Write-ColoredText "`n✓ 搜索完成`n" $Colors.Green
