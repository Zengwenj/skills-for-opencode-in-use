---
name: office-docs-writer
description: Use when generating Chinese official or enterprise documents and when DOCX output must preserve Chinese fonts, heading levels, and character-based indentation under explicit validation.
---

# office-docs-writer

## 用途
生成中文机关/企业公文：专题会议记录、学习记录、工作总结、工作简报、新闻稿、会议纪要等。

## 启用方式

```
task(
  category="unspecified-high",
  load_skills=["office-docs-writer"],
  description="生成[文档类型]",
  prompt="..."
)
```

## 支持文档类型

| 类型 | 成熟度 | 对应 quick-prompts/ |
|------|--------|-------------------|
| 专题会议记录 | ★★★★★ | thematic-record.md |
| 学习记录 | ★★★★☆ | study-record.md |
| 工作总结 | ★★★☆☆ | work-summary.md |
| 工作简报 | ★★★☆☆ | work-brief.md |
| 新闻稿 | ★★★☆☆ | news-snippet.md |
| 会议纪要 | ★★☆☆☆ | meeting-minutes.md |

## 核心资源

- **agent-config.md** — agent 路由与调用约定（必读）
- **agent-workflow.md** — 用户操作指南
- **quick-prompts/** — 各文档类型的结构化输入模板
- **document-types/** — 各类型详细模板与校验清单
- **guidelines/** — 格式规范、政治表述、信息源处理
- **validators/** — 五类校验清单
- **workflows/** — 通用写作流程与多源融合协议
- **templates/** — 遗留兼容模板（新任务请用 document-types/）

## DOCX 约束

- 本 skill 提供的是**写作规范 + 验收约束**，不是自动可靠的 DOCX 格式化器
- 若输出目标是 `.docx`，必须先确认实际生成链能写入 `w:eastAsia`、`w:firstLineChars`、Heading 1/2/3/4（或等效 `w:outlineLvl`）
- 若目标字体未安装，或生成链无法校验上述 XML 属性，必须显式说明风险，不能宣称“已符合格式规范”
- 若发生字体替代，只能表述为“替代输出并附风险说明”，不能表述为“指定字体已合规落地”

## 关键约定

1. 所有组织/年份/路径信息通过上下文变量注入，不硬编码
2. 格式遵循 guidelines/formal-style.md 规定的两种版式
3. 政治表述准确性参照 guidelines/political-stance.md
4. 生成后必须逐项过 validators/ 中相关校验清单
5. DOCX 输出不能只看视觉效果，必须验证标题样式、大纲级别、中文字体与首行字符缩进是否真实落地
