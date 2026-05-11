#!/bin/bash
#
# Obsidian 四层基础搜索故障转移脚本
# 自动选择最佳可用搜索方案
#

set -e

# 配置
VAULT_PATH="${OBSIDIAN_VAULT:-D:\ObsBocdVault}"
OMNISEARCH_PORT="${OMNISEARCH_PORT:-51361}"
TIMEOUT="${SEARCH_TIMEOUT:-3}"
LIMIT="${2:-10}"
QUERY="$1"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 检查参数
if [ -z "$QUERY" ]; then
    echo -e "${RED}错误: 请提供搜索关键词${NC}"
    echo "用法: $0 <关键词> [结果数量]"
    exit 1
fi

echo -e "${BLUE}🔍 搜索: $QUERY${NC}\n"

# 计数器
SEARCH_METHOD=""
RESULT_COUNT=0

# 方案 1: Omnisearch HTTP (Obsidian 运行中)
try_omnisearch() {
    local endpoint="http://localhost:${OMNISEARCH_PORT}/search"
    
    if curl -s --max-time $TIMEOUT "${endpoint}?q=test" &>/dev/null; then
        echo -e "${GREEN}✓ 使用 Omnisearch HTTP 搜索${NC}\n"
        
        local result
        result=$(curl -s --max-time $TIMEOUT "${endpoint}?q=${QUERY}&limit=${LIMIT}")
        
        if [ -n "$result" ] && [ "$result" != "[]" ]; then
            echo "$result" | jq -r '
                .[] | 
                "📄 \(.path)" +
                "\n   相关度: \(.score // "N/A")" +
                "\n   摘要: \(.excerpt[0:200] // "无摘要")" +
                "\n"
            '
            return 0
        fi
    fi
    return 1
}

# 方案 2: 官方 CLI (Obsidian 运行中)
try_official_cli() {
    if command -v obsidian &>/dev/null; then
        if timeout $TIMEOUT obsidian search query="test" format=json &>/dev/null; then
            echo -e "${GREEN}✓ 使用官方 CLI 搜索${NC}\n"
            
            local result
            result=$(timeout $TIMEOUT obsidian search query="$QUERY" format=json limit=$LIMIT 2>/dev/null)
            
            if [ -n "$result" ] && [ "$result" != "[]" ]; then
                echo "$result" | jq -r '
                    .[] | 
                    "📄 \(.path)" +
                    "\n   相关度: \(.score // "N/A")" +
                    "\n   摘要: \(.excerpt[0:200] // "无摘要")" +
                    "\n"
                '
                return 0
            fi
        fi
    fi
    return 1
}

# 方案 3: obs 社区 CLI (独立运行)
try_obs_cli() {
    if command -v obs &>/dev/null; then
        echo -e "${YELLOW}⚠ Obsidian 未运行，使用离线搜索 (obs CLI)${NC}\n"
        
        local result
        result=$(obs search content "$QUERY" --limit $LIMIT --json 2>/dev/null)
        
        if [ -n "$result" ] && [ "$result" != "[]" ]; then
            echo "$result" | jq -r '
                .[] | 
                "📄 \(.file):\(.line)" +
                "\n   内容: \(.content[0:200])" +
                "\n"
            '
            return 0
        fi
    fi
    return 1
}

# 方案 4: ripgrep (零依赖兜底)
try_ripgrep() {
    if command -v rg &>/dev/null; then
        echo -e "${YELLOW}⚠ 使用本地 ripgrep 搜索（结果可能不完整）${NC}\n"
        
        if [ -d "$VAULT_PATH" ]; then
            rg "$QUERY" "$VAULT_PATH" --type md -n --context 2 | head -50 | while IFS= read -r line; do
                echo "📝 $line"
            done
        else
            echo -e "${RED}错误: Vault 路径不存在: $VAULT_PATH${NC}"
            echo "请设置 OBSIDIAN_VAULT 环境变量"
        fi
        return 0
    elif command -v grep &>/dev/null; then
        echo -e "${YELLOW}⚠ 使用 grep 搜索（较慢）${NC}\n"
        
        if [ -d "$VAULT_PATH" ]; then
            grep -rn "$QUERY" "$VAULT_PATH"/*.md 2>/dev/null | head -50 | while IFS= read -r line; do
                echo "📝 $line"
            done
        fi
        return 0
    fi
    return 1
}

# 执行搜索（按优先级）
if try_omnisearch; then
    SEARCH_METHOD="omnisearch"
elif try_official_cli; then
    SEARCH_METHOD="official_cli"
elif try_obs_cli; then
    SEARCH_METHOD="obs_cli"
elif try_ripgrep; then
    SEARCH_METHOD="ripgrep"
else
    echo -e "${RED}❌ 错误: 所有搜索方案都不可用${NC}"
    echo ""
    echo "请检查以下事项："
    echo "1. Obsidian 是否安装并运行"
    echo "2. Omnisearch 插件是否启用 HTTP server"
    echo "3. obs CLI 是否安装: npm install -g obsidian-vault-cli"
    echo "4. ripgrep 是否安装: brew install ripgrep"
    exit 1
fi

echo -e "\n${GREEN}✓ 搜索完成${NC}"
