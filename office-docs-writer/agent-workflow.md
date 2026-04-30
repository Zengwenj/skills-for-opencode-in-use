# office-docs-writer 用户操作指南

## 快速开始

### 第一步：选择文档类型

查看 quick-prompts/ 目录，选择对应的输入模板文件。

### 第二步：填写输入模板

打开 quick-prompts/[类型].md，按字段填写你掌握的信息。
不确定或暂无的信息可标注"待补"或留空。

### 第三步：发起任务

```
task(
  category="unspecified-high",
  load_skills=["office-docs-writer"],
  description="生成[文档类型]",
  prompt="[填写完整的 quick-prompt 内容]"
)
```

## 输入说明

### 信息源类型
- **本地文件**：提供文件路径，agent 读取
- **网页内容**：提供 URL 或复制内容
- **用户提供文本**：直接在 prompt 中粘贴
- **混合源**：参见 sources/mixed-source-input-template.md

### 常见问题

**Q：信息不完整时怎么办？**
在输入模板中标注"待补"，agent 会在起草时标记需要补充的位置，不会凭空编造。

**Q：格式不符合要求怎么办？**
在 prompt 中说明具体格式要求，或在修改请求中指出。
格式基准参见 guidelines/formal-style.md。

**Q：如何处理政治表述？**
agent 会参照 guidelines/political-stance.md。
如有特定会议精神需要体现，请在信息源中提供相关材料。

**Q：生成结果需要修改怎么办？**
继续在同一 session 中发送修改要求，无需重新提供所有背景信息。

## 输出格式

所有文档默认采用**普通页面版式**：
- 上下边距 2.54cm，左右边距 3.18cm
- 正文行距 28 磅，标题行距 40 磅
- 首行缩进 2 字符

如需**公文页面版式**（上37mm/下35mm/左28mm/右26mm），在 prompt 中注明。
如需**红头**，也需在 prompt 中明确注明；未注明时默认不启用红头、发文字号和红色分隔线版头结构。

## 校验流程

文档生成后，agent 会依次核查：
1. 事实准确性（validators/factual-checklist.md）
2. 信息源覆盖（validators/source-coverage-checklist.md）
3. 政策一致性（validators/policy-alignment-checklist.md）
4. 格式规范（validators/style-checklist.md）
5. 敏感内容（validators/sensitive-content-checklist.md）

发现问题时会标注，由用户确认后修正。
