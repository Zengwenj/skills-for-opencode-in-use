#!/usr/bin/env pwsh
# Obsidian Unified Search - Windows PowerShell Edition
# 简化版，避免编码问题

param(
    [Parameter(Mandatory=$true)]
    [string]$Query,
    
    [Parameter(Mandatory=$false)]
    [int]$Limit = 10
)

$VAULT_PATH = $env:OBSIDIAN_VAULT
if (-not $VAULT_PATH) {
    $VAULT_PATH = "D:\ObsBocdVault"
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "   Obsidian Unified Search" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Query: $Query" -ForegroundColor Yellow
Write-Host "Vault: $VAULT_PATH" -ForegroundColor Gray
Write-Host "========================================`n" -ForegroundColor Cyan

# Function: Search via Omnisearch HTTP
function Search-Omnisearch {
    param([string]$q, [int]$lim)
    
    try {
        $url = "http://localhost:51361/search?q=$([uri]::EscapeDataString($q))&limit=$lim"
        $response = Invoke-WebRequest -Uri $url -TimeoutSec 3 -ErrorAction Stop
        $data = $response.Content | ConvertFrom-Json
        
        if ($data) {
            Write-Host "[Omnisearch HTTP] Found $($data.Count) results" -ForegroundColor Green
            $i = 1
            foreach ($item in $data) {
                Write-Host "`n$i. File: $($item.path)" -ForegroundColor Cyan
                Write-Host "   Score: $($item.score)" -ForegroundColor Gray
                if ($item.excerpt) {
                    $excerpt = $item.excerpt.Substring(0, [Math]::Min(150, $item.excerpt.Length))
                    Write-Host "   Excerpt: $excerpt..." -ForegroundColor White
                }
                $i++
            }
            return $true
        }
    } catch {
        return $false
    }
    return $false
}

# Function: Search via Official CLI
function Search-ObsidianCLI {
    param([string]$q, [int]$lim)
    
    try {
        $output = obsidian search query="$q" format=json limit=$lim 2>&1
        $data = $output | ConvertFrom-Json -ErrorAction Stop
        
        if ($data) {
            Write-Host "`n[Obsidian CLI] Found $($data.Count) results" -ForegroundColor Green
            $i = 1
            foreach ($item in $data) {
                Write-Host "`n$i. File: $($item.path)" -ForegroundColor Cyan
                if ($item.score) {
                    Write-Host "   Score: $($item.score)" -ForegroundColor Gray
                }
                if ($item.excerpt) {
                    $excerpt = $item.excerpt.Substring(0, [Math]::Min(150, $item.excerpt.Length))
                    Write-Host "   Excerpt: $excerpt..." -ForegroundColor White
                }
                $i++
            }
            return $true
        }
    } catch {
        return $false
    }
    return $false
}

# Function: Search via ripgrep fallback
function Search-Ripgrep {
    param([string]$q, [int]$lim)
    
    try {
        $rgPath = Get-Command rg -ErrorAction SilentlyContinue
        if (-not $rgPath) {
            # Try git grep
            $result = git -C $VAULT_PATH grep -n "$q" -- "*.md" 2>$null | Select-Object -First $lim
            if ($result) {
                Write-Host "`n[Git Grep Fallback] Results:" -ForegroundColor Yellow
                $result | ForEach-Object { Write-Host "  $_" -ForegroundColor White }
                return $true
            }
        } else {
            $result = & rg $q $VAULT_PATH --type md -n -C 2 2>$null | Select-Object -First $lim
            if ($result) {
                Write-Host "`n[Ripgrep Fallback] Results:" -ForegroundColor Yellow
                $result | ForEach-Object { Write-Host "  $_" -ForegroundColor White }
                return $true
            }
        }
    } catch {
        return $false
    }
    return $false
}

# Main execution
$found = $false

# Try Omnisearch HTTP first (fastest)
if (-not $found) {
    Write-Host "Trying Omnisearch HTTP..." -ForegroundColor Gray
    $found = Search-Omnisearch -q $Query -lim $Limit
}

# Fallback to Official CLI
if (-not $found) {
    Write-Host "Trying Obsidian CLI..." -ForegroundColor Gray
    $found = Search-ObsidianCLI -q $Query -lim $Limit
}

# Final fallback to ripgrep
if (-not $found) {
    Write-Host "Trying local search (fallback)..." -ForegroundColor Gray
    $found = Search-Ripgrep -q $Query -lim $Limit
}

if (-not $found) {
    Write-Host "`nNo results found or all search methods failed." -ForegroundColor Red
    Write-Host "Please ensure:" -ForegroundColor Yellow
    Write-Host "  1. Obsidian is running with Omnisearch HTTP enabled" -ForegroundColor Gray
    Write-Host "  2. Or use Git Bash with: bash ~/.config/opencode/skills/obsidian-unified-search/scripts/smart-search.sh '$Query'" -ForegroundColor Gray
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Search completed" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
