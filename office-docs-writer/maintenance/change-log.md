# 变更日志

## [年份]-03-12（格式标准化）

### 变更内容
- `guidelines/formal-style.md`: 删除 Word 操作指南章节，保留两种页面版式规范；正文行距从 30 磅更新为 28 磅
- `quick-templates.md`: 删除每次调用时的自定义格式参数，改为统一引用格式规范
- `validators/style-checklist.md`: 增加基准版式说明

---

## [年份]-03-10（结构重构，v2）

### 变更内容
- `SKILL.md`: 从 403 行压缩至 71 行，改为薄入口
- `README.md`: 新增结构图和各层状态表
- `agent-config.md`: 从 555 行压缩至 97 行，统一路由逻辑，删除 `branch-office-writer` 残留
- `agent-workflow.md`: 从 799 行压缩至 109 行，删除 `✅已自动` 类成功状态语言
- `workflows/general-writing-workflow.md`: 重写为 9 行抽象流程
- `document-types/`: 迁移 thematic-meeting-record 主链到此目录；新增 work-summary、work-brief、news-snippet 三件套
- `validators/`: 全部重写为中文
- `templates/meeting-record-party-discipline.md`: 降级为 legacy 兼容层

---

## [年份]-03-10（去硬编码）

### 变更内容
- 所有文件：将 `2024`、`D:\`、`成都银行`/`成都锦行`、`支行`、`总行`、`四川省`/`成都市` 等硬编码值替换为占位符
- 新增 `guidelines/context-variables.md`：统一占位符命名规范
- 新增 `maintenance/hardcoding-review-checklist.md`：硬编码自查清单

---

## [年份]-03-10（初始重建）

### 变更内容
- 早期从 `office-report-writer-module` 重命名为 `office-docs-module`
- 当前技能名已统一为 `office-docs-writer`，agent 名同步为 `office-docs-writer`
- 建立分层目录结构（document-types/, sources/, workflows/, validators/, examples/, quick-prompts/, maintenance/）
- 完成 thematic-meeting-record、study-record 模板
- 新增 `workflows/source-fusion-workflow.md`
