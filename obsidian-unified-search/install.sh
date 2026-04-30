#!/bin/bash
#
# Obsidian 统一搜索 - 快速安装脚本
#

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}    Obsidian 统一搜索 - 快速安装${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo ""

# 检查平台
PLATFORM=$(uname -s)
echo -e "${BLUE}检测平台: $PLATFORM${NC}"
echo ""

# 安装 obs CLI (备用方案)
install_obs_cli() {
    echo -e "${BLUE}安装 obs 社区 CLI...${NC}"
    
    if command -v npm &>/dev/null; then
        npm install -g obsidian-vault-cli
        echo -e "${GREEN}✅ obs CLI 安装完成${NC}"
        
        # 配置 vault
        echo -e "${BLUE}配置 vault...${NC}"
        obs init
    else
        echo -e "${YELLOW}⚠️ npm 未安装，跳过 obs CLI${NC}"
        echo -e "   请安装 Node.js: https://nodejs.org/"
    fi
}

# 安装 ripgrep (应急方案)
install_ripgrep() {
    echo -e "${BLUE}安装 ripgrep...${NC}"
    
    if command -v rg &>/dev/null; then
        echo -e "${GREEN}✅ ripgrep 已安装${NC}"
        return 0
    fi
    
    case $PLATFORM in
        Darwin)
            if command -v brew &>/dev/null; then
                brew install ripgrep
            else
                echo -e "${YELLOW}⚠️ Homebrew 未安装，跳过 ripgrep${NC}"
            fi
            ;;
        Linux)
            if command -v apt &>/dev/null; then
                sudo apt update && sudo apt install -y ripgrep
            elif command -v yum &>/dev/null; then
                sudo yum install -y ripgrep
            elif command -v pacman &>/dev/null; then
                sudo pacman -S ripgrep
            else
                echo -e "${YELLOW}⚠️ 未找到包管理器，跳过 ripgrep${NC}"
            fi
            ;;
        CYGWIN*|MINGW*|MSYS*)
            if command -v choco &>/dev/null; then
                choco install ripgrep
            elif command -v scoop &>/dev/null; then
                scoop install ripgrep
            else
                echo -e "${YELLOW}⚠️ Windows: 请手动安装 ripgrep${NC}"
            fi
            ;;
        *)
            echo -e "${YELLOW}⚠️ 未知平台，跳过 ripgrep${NC}"
            ;;
    esac
}

# 创建快捷别名
create_alias() {
    echo ""
    echo -e "${BLUE}创建快捷别名...${NC}"
    
    SHELL_RC=""
    if [ -f "$HOME/.zshrc" ]; then
        SHELL_RC="$HOME/.zshrc"
    elif [ -f "$HOME/.bashrc" ]; then
        SHELL_RC="$HOME/.bashrc"
    fi
    
    if [ -n "$SHELL_RC" ]; then
        ALIAS_LINE='alias obs-search="~/.config/opencode/skills/obsidian-unified-search/scripts/smart-search.sh"'
        if ! grep -q "$ALIAS_LINE" "$SHELL_RC" 2>/dev/null; then
            echo "" >> "$SHELL_RC"
            echo "# Obsidian 统一搜索" >> "$SHELL_RC"
            echo "$ALIAS_LINE" >> "$SHELL_RC"
            echo -e "${GREEN}✅ 已添加到 $SHELL_RC${NC}"
            echo -e "   运行: ${CYAN}source $SHELL_RC${NC} 以启用"
        else
            echo -e "${YELLOW}⚠️ 别名已存在${NC}"
        fi
    fi
}

# 主流程
main() {
    # 询问安装哪些组件
    echo "选择要安装的组件:"
    echo ""
    
    read -p "安装 obs 社区 CLI (备用方案)? [Y/n]: " install_obs
    install_obs=${install_obs:-Y}
    
    read -p "安装 ripgrep (应急方案)? [Y/n]: " install_rg
    install_rg=${install_rg:-Y}
    
    echo ""
    
    # 执行安装
    if [[ $install_obs =~ ^[Yy]$ ]]; then
        install_obs_cli
        echo ""
    fi
    
    if [[ $install_rg =~ ^[Yy]$ ]]; then
        install_ripgrep
        echo ""
    fi
    
    create_alias
    
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}    安装完成!${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BLUE}使用方法:${NC}"
    echo -e "  1. 直接运行:"
    echo -e "     ${CYAN}~/.config/opencode/skills/obsidian-unified-search/scripts/smart-search.sh \"关键词\"${NC}"
    echo ""
    echo -e "  2. 使用别名 (如果已创建):"
    echo -e "     ${CYAN}obs-search \"关键词\"${NC}"
    echo ""
    echo -e "  3. 在 OpenCode 中使用:"
    echo -e "     ${CYAN}帮我搜索和\"项目进度\"相关的资料${NC}"
    echo ""
    echo -e "  4. 检测环境:"
    echo -e "     ${CYAN}~/.config/opencode/skills/obsidian-unified-search/scripts/check-env.sh${NC}"
    echo ""
    echo -e "${YELLOW}注意:${NC} 主方案需要 Obsidian 运行并配置 Omnisearch HTTP"
}

main
