# 待办事项

## 高优先级

- [ ] 补充 `document-types/thematic-meeting-record/` 的真实示例（去敏感化后）
- [ ] 补充 `document-types/study-record/` 的真实示例
- [ ] 审查所有模板中的政治表述，确保符合当前有效会议和政策精神

## 中优先级

- [ ] 完善 `document-types/work-summary/` 三件套（当前为 draft 状态）
- [ ] 完善 `document-types/work-brief/` 三件套（当前为 draft 状态）
- [ ] 完善 `document-types/news-snippet/` 三件套（当前为 draft 状态）
- [ ] 完善 `document-types/meeting-minutes/` 三件套（当前为 lightweight 状态）

## 低优先级

- [ ] 在 `examples/` 目录补充真实示例文档
- [ ] 更新 `maintenance/source-catalog.md` 记录常用信息源
- [ ] 考虑是否整合或删除 legacy `templates/` 层（已有 `document-types/` 替代）
- [ ] 完整国标版记规范（抄送机关/印发机关/印发日期/密级等，当前仅覆盖三段式版记）
- [ ] 正文业务 Markdown 表格转 Word 表格策略（当前仅分类但未提供转换规范）
- [ ] 多页文档版记位置（是否必须在最后一页页脚区域）
- [ ] 版记日期占位符处理（`XX月XX日` 待定日期时 agent 应如何处理）
- [ ] 共印份数来源（硬编码 vs 上下文变量）
- [ ] `.doc`（非 `.docx`）历史稿的处理流程（python-docx 不支持 .doc）

## 已关闭

- [x] 删除所有硬编码的机构名称、路径、年份
- [x] 统一正文行距为 28 磅（2026-03-12）
- [x] 删除 `自动✅` 类成功状态语言
- [x] 删除 agent-config.md 中的 `branch-office-writer` 残留
