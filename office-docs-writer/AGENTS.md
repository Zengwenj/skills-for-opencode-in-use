# office-docs-writer — 中文机关/企业公文生成技能

## 概述

生成符合机关/企业公文规范的中文文档：专题会议记录、学习记录、工作总结、工作简报、新闻稿、会议纪要等。

**核心定位**：提供写作规范 + 验收约束，不是自动 DOCX 格式化器。

## 调用方式

```
task(
  category="unspecified-high",
  load_skills=["office-docs-writer"],
  description="生成[文档类型]",
  prompt="..."
)
```

## 文档类型路由

| 关键词 | 路由到 | 成熟度 |
|--------|--------|--------|
| 专题会议记录、党风廉政专题会、支委会记录 | `document-types/thematic-meeting-record/` | ★★★★★ |
| 学习记录、学习心得、学习体会 | `document-types/study-record/` | ★★★★☆ |
| 工作总结、年终总结、阶段性总结 | `document-types/work-summary/` | ★★★☆☆ |
| 工作简报、情况汇报、进展汇报 | `document-types/work-brief/` | ★★★☆☆ |
| 新闻稿、活动报道、信息稿 | `document-types/news-snippet/` | ★★★☆☆ |
| 会议纪要 | `document-types/meeting-minutes/` | ★★☆☆☆ |

## 资源结构

```
├── agent-config.md           ← 权威路由配置（必读）
├── document-types/           ← 7 种文档类型，每种含 template.md + checklist.md
├── quick-prompts/            ← 6 个结构化输入模板
├── guidelines/               ← 4 个通用规范
│   ├── formal-style.md       ← 格式规范（普通页面/公文页面两种版式）
│   ├── political-stance.md   ← 政治表述准确性
│   ├── context-variables.md  ← 变量命名约定
│   ├── information-source.md ← 信息源处理
│   ├── footer-imprint.md ← 版记结构规范（联系人/印发单位/共印份数）
│   └── historical-docx-reference.md ← 历史 DOCX 检索与复刻协议
├── validators/               ← 5 个校验清单
├── workflows/                ← 2 个工作流程
│   └── source-fusion-workflow.md ← 多源融合协议
├── templates/                ← 6 个遗留兼容模板（新任务用 document-types/）
├── sources/                  ← 2 个信息源说明
└── maintenance/              ← 4 个维护文件
```

## 执行流程

1. **路由**：根据关键词匹配 `document-types/[类型]/`
2. **加载规范**：`guidelines/formal-style.md` + `political-stance.md` + `context-variables.md`
3. **DOCX 前置检查**（仅 `.docx` 输出时）：
   - 中文字体是否已安装
   - 生成链是否支持 `w:eastAsia`、`w:firstLineChars`、`w:outlineLvl`
   - 任一缺失 → 显式报告风险，不能宣称符合格式
> **3.5 版记检查**（仅红头/带版记文档）：参阅 `guidelines/footer-imprint.md`；有历史稿时须先执行 `guidelines/historical-docx-reference.md` 四步协议

4. **信息源处理**：按 `workflows/source-fusion-workflow.md` 融合用户材料
5. **起草**：用 `document-types/[类型]/template.md` 结构
6. **校验**：过 `validators/` 中相关清单
7. **DOCX 后置校验**：验证标题样式、大纲级别、中文字体、首行字符缩进
8. **输出**：仅校验通过后交付

## DOCX 硬约束

- 必须验证 `w:eastAsia`（中文字体）、`w:firstLineChars="200"`（首行缩进）、`w:outlineLvl`（大纲级别）
- 字体未安装或 XML 无法验证 → 不能宣称"已符合格式规范"
- 字体替代发生 → 表述为"替代输出并附风险说明"
- 标题段不能降级为正文样式
- 含版记文档必须先检查历史稿结构再写版记，不得凭经验推断（详见 `guidelines/historical-docx-reference.md`）

## 格式默认值

- 默认普通页面版式（非公文版式）
- 红头非默认项，仅当用户明确要求或文种要求时启用

## 禁止行为

- 硬编码组织名称、年份、路径
- 在文中出现"已读取/已加载/已生成"等执行状态语言
- 跳过 validators/ 校验
- 字体未安装时宣称 DOCX 已符合指定字体要求
