# document-types 目录说明

## 概述

本目录按文档类型组织，每个子目录包含三件套：

- **template.md** — 文档结构模板（各段落标题与填写指引）
- **checklist.md** — 类型专属校验清单
- **source-requirements.md** — 生成该类文档所需的信息源要求

## 成熟度

| 目录 | 成熟度 | 说明 |
|------|--------|------|
| thematic-meeting-record/ | ★★★★★ | 主要专题会议链，最完整 |
| study-record/ | ★★★★☆ | 学习记录，较完整 |
| work-summary/ | ★★★☆☆ | 工作总结，草稿阶段 |
| work-brief/ | ★★★☆☆ | 工作简报，草稿阶段 |
| news-snippet/ | ★★★☆☆ | 新闻稿，草稿阶段 |
| meeting-minutes/ | ★★☆☆☆ | 会议纪要，轻量版 |

## 使用方式

agent-config.md 中的路由逻辑会根据用户请求自动加载对应子目录资源。
也可在 prompt 中直接指定：`参照 document-types/thematic-meeting-record/ 生成...`
