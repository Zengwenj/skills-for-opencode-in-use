#!/bin/bash
#
# Obsidian 统一搜索环境检测脚本
# 检查基础搜索方案与官方 Obsidian CLI 高级查询能力
#

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Vault 路径说明：
# - OBSIDIAN_VAULT：用户自定义环境变量，优先级最高
# - DEFAULT_VAULT_PATH：通用默认值（当前本机示例路径）
DEFAULT_VAULT_PATH='D:\ObsBocdVault'
VAULT_PATH="${OBSIDIAN_VAULT:-$DEFAULT_VAULT_PATH}"
OMNISEARCH_PORT="${OMNISEARCH_PORT:-51361}"

# 计数器
AVAILABLE_COUNT=0
OBSIDIAN_CMD_CALLABLE=0

echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}    Obsidian 统一搜索 - 环境检测${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo ""

# 检测 1: Omnisearch HTTP
echo -e "${BLUE}🔍 检测 Omnisearch HTTP...${NC}"
if curl -s --max-time 2 "http://localhost:${OMNISEARCH_PORT}/search?q=test" &>/dev/null; then
    echo -e "  ${GREEN}✅ 可用${NC} - HTTP 端点响应正常"
    echo -e "     端口: ${OMNISEARCH_PORT}"
    
    # 测试搜索
    if command -v jq &>/dev/null; then
        TEST_RESULT=$(curl -s "http://localhost:${OMNISEARCH_PORT}/search?q=obsidian&limit=1" | jq -r '.[0].path' 2>/dev/null)
        if [ -n "$TEST_RESULT" ]; then
            echo -e "     索引状态: ${GREEN}正常${NC}"
        else
            echo -e "     索引状态: ${YELLOW}可能需要重新索引${NC}"
        fi
    else
        echo -e "     索引状态: ${YELLOW}无法解析${NC}"
        echo -e "     ${CYAN}说明:${NC} 缺少 jq，已跳过索引结果解析"
    fi
    ((AVAILABLE_COUNT+=1))
else
    echo -e "  ${RED}❌ 不可用${NC}"
    echo -e "     ${YELLOW}原因:${NC}"
    echo -e "       - Obsidian 未运行"
    echo -e "       - Omnisearch 插件未安装"
    echo -e "       - HTTP server 未启用"
    echo ""
    echo -e "     ${CYAN}解决方案:${NC}"
    echo -e "       1. 启动 Obsidian"
    echo -e "       2. 安装 Omnisearch 插件"
    echo -e "       3. 设置 → Omnisearch → Enable HTTP server"
fi
echo ""

# 检测 2: 官方 CLI
echo -e "${BLUE}🔍 检测官方 Obsidian CLI...${NC}"
if command -v obsidian &>/dev/null; then
    OBSIDIAN_CMD_CALLABLE=1
    CLI_VERSION=$(obsidian --version 2>/dev/null | head -1)
    [ -n "$CLI_VERSION" ] || CLI_VERSION="unknown"
    echo -e "  ${GREEN}✅ 已安装${NC} - 版本: $CLI_VERSION"
    
    # 检查 Obsidian 是否运行
    if timeout 2 obsidian search query="test" format=json &>/dev/null; then
        echo -e "     Obsidian 状态: ${GREEN}运行中${NC}"
        ((AVAILABLE_COUNT+=1))
    else
        echo -e "     Obsidian 状态: ${YELLOW}未运行${NC}"
        echo -e "     ${YELLOW}注意:${NC} CLI 已安装但 Obsidian 未启动"
    fi
else
    echo -e "  ${RED}❌ 未安装${NC}"
    echo -e "     ${YELLOW}原因:${NC} CLI 未注册到 PATH"
    echo ""
    echo -e "     ${CYAN}解决方案:${NC}"
    echo -e "       1. 打开 Obsidian"
    echo -e "       2. Settings → General → Command line interface"
    echo -e "       3. 点击 'Register' 按钮"
    echo -e "       4. 重启终端"
fi
echo ""

# 检测 2b: 官方 Obsidian CLI 高级查询能力
echo -e "${BLUE}🔍 检测官方 Obsidian CLI 高级查询能力...${NC}"
if [ "$OBSIDIAN_CMD_CALLABLE" -eq 1 ]; then
    echo -e "  ${GREEN}✅ 可调用${NC} - 官方 obsidian 命令已在 PATH 中"
    echo -e "     能力范围: tasks / tags / properties / backlinks / links / outline / read"
    echo -e "     ${CYAN}说明:${NC} 这里只检查命令可调用性，不执行任何会修改 Vault 的命令"
else
    echo -e "  ${YELLOW}⚠️ 不可用${NC} - 未找到官方 obsidian 命令"
    echo -e "     ${CYAN}说明:${NC} 基础搜索仍可继续依赖 Omnisearch、obs CLI 或 ripgrep"
fi
echo ""

# 检测 3: obs 社区 CLI
echo -e "${BLUE}🔍 检测 obs 社区 CLI...${NC}"
if command -v obs &>/dev/null; then
    OBS_VERSION=$(obs --version 2>/dev/null || echo "unknown")
    echo -e "  ${GREEN}✅ 已安装${NC} - 版本: $OBS_VERSION"
    
    # 检查 vault 配置
    if obs vault info &>/dev/null; then
        VAULT_INFO=$(obs vault info 2>/dev/null | head -1)
        echo -e "     Vault: ${GREEN}已配置${NC}"
        echo -e "     $VAULT_INFO"
        ((AVAILABLE_COUNT+=1))
    else
        echo -e "     Vault: ${YELLOW}未配置${NC}"
        echo -e "     ${CYAN}运行:${NC} obs init"
    fi
else
    echo -e "  ${RED}❌ 未安装${NC}"
    echo -e "     ${CYAN}安装命令:${NC}"
    echo -e "       npm install -g obsidian-vault-cli"
fi
echo ""

# 检测 4: ripgrep
echo -e "${BLUE}🔍 检测 ripgrep...${NC}"
if command -v rg &>/dev/null; then
    RG_VERSION=$(rg --version | head -1)
    echo -e "  ${GREEN}✅ 已安装${NC} - $RG_VERSION"
    ((AVAILABLE_COUNT+=1))
else
    echo -e "  ${YELLOW}⚠️ 未安装${NC} (可选)"
    echo -e "     ${CYAN}安装命令:${NC}"
    echo -e "       macOS:   brew install ripgrep"
    echo -e "       Ubuntu:  sudo apt install ripgrep"
    echo -e "       Windows: choco install ripgrep"
    echo ""
    echo -e "     ${YELLOW}注意:${NC} 将使用 grep 作为替代"
fi
echo ""

# 检测 Vault 路径
echo -e "${BLUE}🔍 检测 Vault 路径...${NC}"
echo -e "  配置路径: ${CYAN}$VAULT_PATH${NC}"
if [ -d "$VAULT_PATH" ]; then
    FILE_COUNT=$(find "$VAULT_PATH" -name "*.md" -type f 2>/dev/null | wc -l)
    echo -e "  状态: ${GREEN}存在${NC}"
    echo -e "  Markdown 文件: ${GREEN}$FILE_COUNT${NC} 个"
else
    echo -e "  状态: ${RED}不存在${NC}"
    echo -e "  ${CYAN}设置环境变量:${NC}"
    echo -e "    export OBSIDIAN_VAULT=\"/path/to/your/vault\""
fi
echo ""

# 总结
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}    检测结果总结${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo ""

if [ $AVAILABLE_COUNT -ge 2 ]; then
    echo -e "${GREEN}✅ 环境良好${NC} - 有 $AVAILABLE_COUNT 个搜索方案可用"
    echo -e "   推荐使用统一搜索脚本进行智能搜索"
elif [ $AVAILABLE_COUNT -eq 1 ]; then
    echo -e "${YELLOW}⚠️ 环境可用${NC} - 只有 1 个搜索方案可用"
    echo -e "   建议安装其他方案作为备用"
else
    echo -e "${RED}❌ 环境不可用${NC} - 没有可用的搜索方案"
    echo -e "   请按照上述解决方案安装至少一个方案"
fi

echo ""
echo -e "${CYAN}测试搜索:${NC}"
echo -e "  ~/.config/opencode/skills/obsidian-unified-search/scripts/smart-search.sh \"测试关键词\""
echo ""

exit 0
