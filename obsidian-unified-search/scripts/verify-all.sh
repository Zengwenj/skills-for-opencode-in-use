#!/bin/bash
# 完整环境验证脚本

echo "========================================"
echo "   Obsidian 三层搜索方案验证"
echo "========================================"
echo ""

VAULT_PATH="${OBSIDIAN_VAULT:-D:\ObsBocdVault}"
echo "Vault 路径: $VAULT_PATH"
echo ""

# 检查 1: 官方 CLI
echo "【检查 1】官方 Obsidian CLI"
if command -v obsidian &>/dev/null; then
    echo "  ✅ 已安装"
    obsidian --version 2>/dev/null | head -1 | sed 's/^/     /'
    
    # 测试搜索
    echo "  测试搜索..."
    if obsidian search query="test" format=json limit=1 &>/dev/null; then
        echo "  ✅ 搜索功能正常"
    else
        echo "  ⚠️  搜索失败（Obsidian 可能未运行）"
    fi
else
    echo "  ❌ 未安装"
fi
echo ""

# 检查 2: 社区 CLI (obs)
echo "【检查 2】社区 CLI (obs)"
if command -v obs &>/dev/null; then
    echo "  ✅ 已安装"
    obs --version | sed 's/^/     /'
    
    # 检查 vault 配置
    if obs vault info &>/dev/null; then
        echo "  ✅ Vault 已配置"
        obs vault info 2>&1 | grep -E "(Vault:|Path:|Files:)" | sed 's/^/     /'
    else
        echo "  ⚠️  Vault 未配置"
        echo "     运行: obs vault config defaultVault \"$VAULT_PATH\""
    fi
    
    # 测试搜索
    echo "  测试搜索..."
    if obs search content "test" --limit 1 &>/dev/null; then
        echo "  ✅ 搜索功能正常"
    else
        echo "  ⚠️  搜索失败（可能无匹配内容）"
    fi
else
    echo "  ❌ 未安装"
    echo "     从源码构建:"
    echo "     cd ~/obsidian-vault-cli && npm install && npm run build && npm link"
fi
echo ""

# 检查 3: Omnisearch HTTP
echo "【检查 3】Omnisearch HTTP"
if curl -s --max-time 2 "http://localhost:51361/search?q=test" &>/dev/null; then
    echo "  ✅ 服务运行正常"
    echo "  测试搜索..."
    result=$(curl -s "http://localhost:51361/search?q=欢迎&limit=1")
    if [ -n "$result" ] && [ "$result" != "[]" ]; then
        echo "  ✅ 返回结果正常"
    else
        echo "  ⚠️  返回空结果（可能尚未索引）"
    fi
else
    echo "  ❌ 服务未运行"
    echo "     需要在 Obsidian 中："
    echo "     1. 安装 Omnisearch 插件"
    echo "     2. 启用 HTTP server（端口 51361）"
    echo "     详见: OMNISEARCH_SETUP.md"
fi
echo ""

# 检查 4: ripgrep (可选)
echo "【检查 4】ripgrep (可选)"
if command -v rg &>/dev/null; then
    echo "  ✅ 已安装"
    rg --version | head -1 | sed 's/^/     /'
else
    echo "  ⚠️  未安装（可选）"
    echo "     Windows 安装: choco install ripgrep"
    echo "     或使用 Git Bash 内置的 grep"
fi
echo ""

# 总结
echo "========================================"
echo "   状态总结"
echo "========================================"
echo ""

# 统计可用的方案
available=0
command -v obsidian &>/dev/null && ((available++))
command -v obs &>/dev/null && ((available++))
curl -s --max-time 1 "http://localhost:51361/search?q=test" &>/dev/null && ((available++))

echo "可用搜索方案: $available/3"
echo ""

if [ $available -ge 2 ]; then
    echo "✅ 三层搜索方案已就绪！"
    echo ""
    echo "使用方式:"
    echo "  1. Bash:  ~/.config/opencode/skills/obsidian-unified-search/scripts/smart-search.sh '关键词'"
    echo "  2. PS:    ~/.config/opencode/skills/obsidian-unified-search/scripts/smart-search-simple.ps1 -Query '关键词'"
    echo "  3. OpenCode: 直接说'帮我搜索 XXX'"
else
    echo "⚠️  部分方案未就绪"
    echo ""
    echo "建议操作:"
    command -v obsidian &>/dev/null || echo "  - 在 Obsidian 设置中启用 CLI"
    command -v obs &>/dev/null || echo "  - 安装社区 CLI: cd ~/obsidian-vault-cli && npm install && npm run build && npm link"
    curl -s --max-time 1 "http://localhost:51361/search?q=test" &>/dev/null || echo "  - 在 Obsidian 中安装 Omnisearch 并启用 HTTP"
fi

echo ""
echo "========================================"
