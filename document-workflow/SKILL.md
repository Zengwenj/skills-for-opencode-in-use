---
name: document-workflow
description: "文档生成、文档转换、docx、xlsx、pptx、pdf、Office、Pandoc、MarkItDown、MinerU、转PDF、PDF转Word 等任务的统一全局路由器。当用户请求创建或编辑 Office 文档、转换格式、生成 PDF、把 Office 或 PDF 提取为 Markdown、或把 PDF 重建为 DOCX 时立即加载本 Skill：先看首屏决策表锁定唯一路径，再读对应章节的脚本调用与降级规则。本 Skill 已固化工具链，禁止重复探索。"
---

# 文档工作流路由器

本 Skill 是 OpenCode 在 Windows 环境下所有文档生成与转换任务的入口。加载后第一屏决策表确定唯一执行路径，后续章节只提供该路径所需的脚本与降级规则。**禁止在已加载本 Skill 的情况下重新探索工具链。**

环境基线（2026-07-22 验证通过）：

- OfficeCLI 1.0.135（PATH 可用，MCP 已配置，无插件）
- Microsoft Office 365 Word / Excel / PowerPoint COM 16.0
- Pandoc 3.8.3（PATH）
- MarkItDown 0.1.5（CLI `C:\Users\zengw\anaconda3\Scripts\markitdown.exe`，MCP 已配置）
- Poppler 25.07.0（`pdfinfo` / `pdftotext` / `pdftoppm`，PATH）
- MinerU CLI 0.5.9 + MCP（带 API token，外部解析服务）
- 未安装：LibreOffice、LaTeX / MiKTeX、WeasyPrint、Typst

脚本目录：`C:\Users\zengw\.config\opencode\skills\document-workflow\scripts\`

调用顺序：用户请求 → 加载本 Skill → 看第 1 节决策表锁定路径 → 加载对应子 Skill 或调用脚本 → 输出 → 跑第 4 节交付自检。**任何步骤都不要重新探索工具链。**

## 1. 30 秒决策表

| 目标 | 输入 | 保真类别 | 默认工具 | 降级工具 | 验收 |
|---|---|---|---|---|---|
| 新建 / 编辑 .docx | 文本 / 结构化数据 | 高保真 | `officecli-docx` Skill + OfficeCLI MCP | 无 | `validate` 通过 + `view issues` 干净 |
| 新建 / 编辑 .xlsx | 表格数据 | 高保真 | `officecli-xlsx` Skill + OfficeCLI MCP | 无 | 同上 |
| 新建 / 编辑 .pptx | 幻灯片内容 | 高保真 | `officecli-pptx` Skill + OfficeCLI MCP | 无 | 同上 + `screenshot` 视觉审计 |
| Office → PDF | .docx / .xlsx / .pptx | 高保真 | `Export-OfficePdf.ps1`（Word / Excel / PowerPoint COM） | 无（COM 是唯一可靠路径） | `pdfinfo` 能读 + 文件大小 > 0 |
| Markdown → PDF | .md | 高保真 | `Convert-MarkdownToPdf.ps1`（Pandoc → DOCX → Word COM 两阶段） | 无 | 同上 |
| Office / PDF → Markdown | .docx / .pptx / .xlsx / .pdf | 内容提取 | 简单：MarkItDown（MCP 优先，CLI 兜底） | 复杂 / 扫描 PDF：MinerU MCP；本地失败：Poppler `pdftotext` 纯文本 | Markdown 可读，标题与表格保留 |
| PDF → DOCX | .pdf | 可编辑重建（**非无损**） | 简单文本 PDF：`Convert-PdfToDocx.ps1`（Word COM） | 复杂 / 扫描 PDF：MinerU 提取 → OfficeCLI 重建 | DOCX 可编辑，与原文不逐字一致 |

复杂度判定：页数 > 20、含表格 / 公式 / 多栏、扫描质量差、含手写 / 印章 → 走 MinerU，不走 MarkItDown。

## 2. 路径详细规则

### 2.1 新建 / 编辑 Office 文档

直接加载对应子 Skill 并使用 OfficeCLI MCP。本 Skill 不复制命令，只负责路由。

- **.docx** → 加载 `officecli-docx`
- **.xlsx** → 加载 `officecli-xlsx`
- **.pptx** → 加载 `officecli-pptx`

场景层（按主题在基础 Skill 之上加载）：

| 场景 | 加载的 Skill | 基础 |
|---|---|---|
| 融资路演 / 投资人 deck | `officecli-pitch-deck` | pptx |
| 学术论文 / 期刊稿件 | `officecli-academic-paper` | docx |
| 财务模型 / 三表 / DCF / LBO | `officecli-financial-model` | xlsx |

主题未命中时按基础 Skill（docx / xlsx / pptx）路由。

### 2.2 Office → PDF

```powershell
& "$PSScriptRoot\scripts\Export-OfficePdf.ps1" -InputPath <file> -OutputPath <out.pdf>
```

跨目录调用改用绝对路径：

```powershell
& "C:\Users\zengw\.config\opencode\skills\document-workflow\scripts\Export-OfficePdf.ps1" -InputPath ".\report.docx" -OutputPath ".\report.pdf"
```

底层：Word / Excel / PowerPoint COM 的 `ExportAsFixedFormat`。COM 不可用时无降级，LibreOffice 未安装。

### 2.3 Markdown → PDF

```powershell
& "$PSScriptRoot\scripts\Convert-MarkdownToPdf.ps1" -InputPath <file.md> -OutputPath <out.pdf> [-WorkDir <临时目录>]
```

两阶段流程：Pandoc 把 `.md` 转 `.docx`，再由 Word COM 转 `.pdf`。**禁止**走 Pandoc 的 `--pdf-engine=xelatex|pdflatex|weasyprint|typst` 等路径，对应引擎均未安装。

### 2.4 Office / PDF → Markdown

按下列优先级：

1. **简单 .docx / .pptx / .xlsx / 文本 PDF** → MarkItDown（先 MCP，后 CLI `C:\Users\zengw\anaconda3\Scripts\markitdown.exe`）
2. **复杂版式 / 扫描件 / 表格密集 PDF** → MinerU MCP（带 API token，外部解析）
3. **本地解析失败（编码异常、加密、损坏）** → Poppler 兜底：

   ```powershell
   pdftotext -layout <in.pdf> <out.txt>
   ```

   仅产出纯文本，丢失全部版式与图片，需在回复中明确告知用户。

复杂度判定见第 1 节脚注。MinerU 解析结果如果含 LaTeX 公式或 HTML 表格，按目标 Skill 要求二次清洗后再交付。

### 2.5 PDF → DOCX

**唯一承诺是"可编辑重建"，不承诺与原 PDF 视觉无损一致。**

- **简单文本 PDF**（电子生成、单栏、无复杂表格）：

  ```powershell
  & "$PSScriptRoot\scripts\Convert-PdfToDocx.ps1" -InputPath <file.pdf> -OutputPath <out.docx>
  ```

  底层为 Word COM 直接打开 PDF 并另存 DOCX。

- **复杂 / 扫描 PDF**：MinerU MCP 提取 Markdown / JSON → 加载 `officecli-docx` 用 OfficeCLI 重建 DOCX 结构。

输出 DOCX 前必须在回复中告知用户："这是可编辑重建，不是无损还原。"

## 3. 脚本调用速查

| 脚本 | 必需参数 | 可选参数 | 示例 |
|---|---|---|---|
| `Export-OfficePdf.ps1` | `-InputPath <file>` `-OutputPath <out.pdf>` | — | `& "$PSScriptRoot\scripts\Export-OfficePdf.ps1" -InputPath ".\a.docx" -OutputPath ".\a.pdf"` |
| `Convert-MarkdownToPdf.ps1` | `-InputPath <file.md>` `-OutputPath <out.pdf>` | `-WorkDir <dir>` | `& "$PSScriptRoot\scripts\Convert-MarkdownToPdf.ps1" -InputPath ".\r.md" -OutputPath ".\r.pdf"` |
| `Convert-PdfToDocx.ps1` | `-InputPath <file.pdf>` `-OutputPath <out.docx>` | — | `& "$PSScriptRoot\scripts\Convert-PdfToDocx.ps1" -InputPath ".\r.pdf" -OutputPath ".\r.docx"` |
| `Test-DocumentToolchain.ps1` | — | `-WorkDir <dir>` `-KeepArtifacts` | `& "$PSScriptRoot\scripts\Test-DocumentToolchain.ps1"` |

说明：

- `$PSScriptRoot` 仅在脚本同目录调用时有效。从其它 cwd 调用请改用绝对路径 `C:\Users\zengw\.config\opencode\skills\document-workflow\scripts\<name>.ps1`。
- 输入路径含空格时必须用双引号包裹。
- 输出路径的父目录必须存在；脚本不会自动 `New-Item -ItemType Directory`。

## 4. 交付前自检

按目标类型逐项确认，不通过即返回上一步修复，不交付：

**Office 文档（.docx / .xlsx / .pptx）**

- `officecli validate <file>` 无 error
- `officecli view <file> issues` 无 overflow / format / structure 问题
- 扫描 `view <file> text` 无遗留占位符（`xxxx`、`lorem/ipsum`、`<TODO>`、`{{...}}`、`$VAR$`、空 `()` / `[]`）
- `.pptx` 必须额外跑 `view <file> screenshot --page N`，目视检查重叠、溢出、错位
- 完成后执行 `save <file>` 刷盘

**PDF 输出**

- `pdfinfo <file.pdf>` 能读出 producer / page count
- 文件大小 > 0
- 用 `pdftotext <file.pdf> - | Select-Object -First 20` 抽样确认中文未乱码

**Markdown 提取**

- 标题层级（`#` / `##` / `###`）保留
- 表格单元格未折叠
- 图片引用路径有效（如目标场景需要图片）

**PDF → DOCX 重建**

- 回复中已显式声明"可编辑重建，非无损"
- 用户无视觉一致性的不合理期望

## 5. 禁止行为

- **禁止**承诺 "PDF 无损转 DOCX"。视觉层与逻辑层无法同时保留。
- **禁止**在每次文档任务中重新全盘探索工具链。本 Skill 已固化路径，首屏决策表即终局。
- **禁止**默认使用 LibreOffice（未安装）、LaTeX / MiKTeX（未安装）、WeasyPrint（未安装）、Typst（未安装）作为输出引擎。
- **禁止**绕过 OfficeCLI MCP 直接手写 OOXML 或调用底层 COM API 创建 / 编辑 Office 文档。
- **禁止**用 Pandoc `--pdf-engine` 直出 PDF 替代 Markdown → PDF 的两阶段流程。

## 6. 后端不可用时的处理

仅做**一次**目标后端探测，失败即转入已定义降级，**不重跑全盘工具探测**：

- **OfficeCLI MCP 无响应** → 终止 Office 编辑任务并报告环境问题，不降级到手写 OOXML。
- **Word COM 异常**（Office 未启动 / 许可证失效 / COM 注册损坏）→ Office → PDF、Markdown → PDF、PDF → DOCX 三条链路全部停摆。告知用户必须先修复 Office，**禁止**用 Pandoc 直出 PDF 作为替代。
- **MarkItDown MCP 失败** → 切 MarkItDown CLI；CLI 也失败 → 切 MinerU MCP；都失败 → Poppler `pdftotext` 纯文本兜底（仅适用 PDF）。
- **MinerU MCP 失败**（外网异常 / API token 失效）→ 简单文件降级到 MarkItDown；复杂扫描 PDF 暂停任务并报告，不要硬走 Poppler。
- **Poppler 失败**（PDF 加密 / 损坏）→ 停止任务并报告，不尝试其它路径。

任何降级完成后再失败，立即停止任务并报告环境问题，**不要循环重试**。
