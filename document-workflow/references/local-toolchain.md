# 本机文档工具链环境快照

> 本文为 agent 环境参考，记录 2026-07-22 核验通过的工具路径、版本、能力边界、端到端测试结果与已知限制。所有数据来自五个只读探测子代理的交叉验证、四条 PDF 链路的端到端夹具测试，以及官方文档核验。

## 一、核验信息

| 项目 | 内容 |
|------|------|
| 核验日期 | 2026-07-22 |
| 核验方式 | 只读探测（路径/版本/能力）+ 端到端夹具测试（四条 PDF 链路） |
| 数据来源 | 五个只读探测子代理交叉验证 + 端到端夹具测试实际运行 + 官方文档核验（Pandoc / MarkItDown / MinerU / LibreOffice / OfficeCLI） |
| 下次核验触发条件 | 环境变更后重跑 `scripts/Test-DocumentToolchain.ps1`；新增/升级工具、改 PATH、卸载 Office 或 Anaconda 时强制重核 |

## 二、已验证工具清单

| 工具 | 版本 | 路径 | PATH 可用 | 已验证能力 | 已知限制 |
|------|------|------|-----------|------------|----------|
| OfficeCLI | 1.0.135 | `C:\Users\zengw\AppData\Local\OfficeCLI\officecli.exe` | 是 | .docx / .xlsx / .pptx 的创建、编辑、校验（validate）、问题检查（view issues）、截图、批处理 | 不支持 PDF 导入；PDF 导出依赖尚未验证的插件 |
| Word COM | 16.0（Office 365） | 注册表 App Paths | 否（通过注册表解析） | DOCX 转 PDF（`ExportAsFixedFormat`）；PDF 转 DOCX 可编辑重建 | 不支持 `Visible=$false`（仅 PowerPoint 受此约束，Word/Excel 可隐藏窗口） |
| Excel COM | 16.0（Office 365） | 注册表 App Paths | 否（通过注册表解析） | XLSX 转 PDF（`ExportAsFixedFormat`） | 同 Word，隐藏窗口行为一致 |
| PowerPoint COM | 16.0（Office 365） | 注册表 App Paths | 否（通过注册表解析） | PPTX 转 PDF（`SaveAs`，`ppSaveAsPDF=32`） | `Visible=$false` 会抛异常，必须用 `WithWindow=$false` |
| Pandoc | 3.8.3 | `C:\Program Files\Pandoc\pandoc.exe` | 是 | Markdown 与 DOCX / PPTX / HTML 之间的结构化转换 | 无 PDF 引擎（无 LaTeX / WeasyPrint / wkhtmltopdf），不能直接生成 PDF |
| MarkItDown CLI | 0.1.5 | `C:\Users\zengw\anaconda3\Scripts\markitdown.exe` | 是 | PDF / DOCX / XLSX / PPTX 等文件提取为 Markdown | Python API 在 hermes venv 不可用（numpy 冲突），须用 Anaconda Python 或 CLI 入口 |
| MinerU CLI | 0.5.9 | `C:\Users\zengw\.mineru\bin\mineru-open-api.exe` | 是 | PDF / 图片 转 Markdown / JSON / HTML / LaTeX / DOCX；公式转 LaTeX；表格转 HTML；OCR 支持 109 种语言 | 依赖外部解析服务（文件上传到 mineru.net）；flash-extract 限 10 MB / 20 页 |
| Poppler | 25.07.0 | `C:\Users\zengw\anaconda3\Library\bin\`（含 `pdftotext.exe` / `pdfinfo.exe` / `pdftoppm.exe`） | 是 | PDF 文本提取、元数据查询、页面渲染为图片 | 仅输出纯文本，不保留格式 |

附注：Ghostscript 10.07.0 与 qpdf 12.3.2 随 PDF24 安装，但未加入 PATH，调用须使用绝对路径。

## 三、端到端测试结果

测试时间截至 2026-07-22，运行 `scripts/Test-DocumentToolchain.ps1` 通过。

| 链路 | 页数 | 中文锚点 | 状态 |
|------|------|----------|------|
| DOCX 转 PDF（Word COM） | 1 | 通过 | 通过 |
| XLSX 转 PDF（Excel COM） | 1 | 通过 | 通过 |
| PPTX 转 PDF（PowerPoint COM） | 1 | 通过 | 通过 |
| Markdown 转 DOCX 转 PDF（Pandoc + Word COM） | 1 | 通过 | 通过 |

## 四、未安装工具

| 工具 | 用途 | 本机替代 |
|------|------|----------|
| LibreOffice / soffice | 无头文档渲染、格式转换 | OfficeCLI + Office COM |
| XeLaTeX / MiKTeX | LaTeX PDF 编译 | Pandoc 转 DOCX，再由 Office COM 转 PDF |
| WeasyPrint | HTML 转 PDF | 无直接替代 |
| Typst | 现代排版 | 无直接替代 |
| wkhtmltopdf | HTML 转 PDF | 无直接替代 |

## 五、已知限制

- PDF 转 DOCX 为"可编辑重建"，非无损转换；版式细节可能漂移。
- MarkItDown 的 Python API 须使用 Anaconda Python（`C:\Users\zengw\anaconda3\python.exe`）；hermes venv 因 numpy 冲突不可用。
- MinerU 使用外部解析服务，敏感文件不应上传；仅适合公开或可外发的资料。
- Ghostscript 10.07.0 与 qpdf 12.3.2 随 PDF24 安装但不在 PATH，调用须用绝对路径。
- PowerPoint COM 不能用 `Visible=$false`，必须改用 `WithWindow=$false`，否则会抛异常。
- Pandoc 自身不能输出 PDF，必须配合 Office COM（DOCX 转 PDF）或安装额外引擎。

## 六、降级路径

当默认后端不可用时，按下列顺序切换。

| 场景 | 默认后端 | 降级方案 |
|------|----------|----------|
| Office 文档转 PDF | Office COM（Word / Excel / PowerPoint） | 改用 OfficeCLI（若其 PDF 插件可用），或安装 LibreOffice 以无头模式渲染 |
| Markdown 转 PDF | Pandoc 转 DOCX 后由 Word COM 转 PDF | 直接由 Pandoc 转 HTML，再以浏览器打印；或安装 WeasyPrint / wkhtmltopdf |
| PDF 提取文本 | Poppler `pdftotext` | MinerU（结构化提取）；或 MarkItDown CLI |
| PDF 转 DOCX | Word COM 重建 | MinerU 输出 DOCX；或 MarkItDown 转 Markdown 再由 Pandoc 重建 |
| 复杂版面 / 公式 PDF 解析 | MinerU | MarkItDown（无公式识别）；或 Poppler 纯文本兜底 |

降级优先级：本机已验证工具 > 未安装工具的临时安装 > 手工干预。涉及敏感文件时，禁用 MinerU 等外部服务，回退到本机工具链。