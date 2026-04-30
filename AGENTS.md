# SkillsSetup — OpenCode AI Agent Skills 工作区

## 工作区定位

本仓库是 OpenCode AI Agent 技能包（skills）的开发与维护工作区。每个子目录是一个独立 skill，包含 SKILL.md（技能定义）及配套资源。

## Skills 总览

| Skill | 类型 | 语言 | 有测试 | 说明 |
|-------|------|------|--------|------|
| `convert-with-mineru` | 代码项目 | Python 3 | ✅ pytest (39 tests) | MineU 文档转 Markdown，精准模式 + 分流路由 |
| `office-docs-writer` | 纯 Markdown | — | — | 中文机关/企业公文生成，DOCX 验证约束 |
| `obsidian-unified-search` | 脚本 | Bash/PowerShell | — | Obsidian 四层故障转移搜索 |
| `article-analysis-imitation` | 纯 Markdown | — | — | 跨文本风格分析与仿写指导 |

## 共享规范

- **SKILL.md 是每个 skill 的权威定义文件**，修改行为前必须先读 SKILL.md
- 非 git 仓库，无 CI/CD。变更需手动测试验证
- convert-with-mineru 是唯一有自动化测试的子项目，修改后务必 `pytest`
- 所有 skill 面向 OpenCode agent 调用，不对外发布 npm/pip 包

## 工作流程

### convert-with-mineru（唯一需要构建的 skill）

```powershell
# 运行
python -m scripts.mineru_convert "C:\docs\file.pdf"

# 测试
pytest

# 分发打包
python -m scripts.stage_distribution ".\dist\convert-with-mineru"
```

### 其他 skills

无构建步骤，修改 .md 文件后直接生效。

## 路由指引

- 文档转换需求 → `convert-with-mineru/`
- 中文公文写作 → `office-docs-writer/`
- Obsidian 搜索 → `obsidian-unified-search/`
- 风格分析/仿写 → `article-analysis-imitation/`

## 注意事项

- `.venv` 在 `convert-with-mineru/` 下，勿修改
- `convert-with-mineru/dist/` 是分发副本，gitignore 管理
- `convert-with-mineru/mineru..env` 可能包含真实 token，视为隔离对象
