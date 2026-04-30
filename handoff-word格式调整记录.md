# handoff-word格式调整记录

## 一、用途

本文档记录本次“工作总结红头 DOCX”生成过程中暴露出的 Word 版式问题、根因定位、历史发文稿格式检索结果、脚本修复方式和验证方法，用于后续提升 `office-docs-writer`、`docx` 或相关公文生成 skill。

核心结论：**中文公文末尾版记不能简单按正文段落写入；需要优先检索历史 `.docx` 发文稿的真实 OOXML 结构，并按表格、边框、字体、行距、浮动位置等参数复刻。**

## 二、任务背景

- 目标源文件：`E:\BocdWorkingProjects\通知公告\支行发文\通知发文拟稿\成银行科技〔2026〕XX号-成都银行科技支行2025年工作总结和2026年工作计划-草稿.md`
- 目标输出：`E:\BocdWorkingProjects\通知公告\支行发文\通知发文拟稿\成银行科技〔2026〕XX号-成都银行科技支行2025年工作总结和2026年工作计划-草稿.docx`
- 生成脚本：`E:\BocdWorkingProjects\.sisyphus\generate_work_summary_redhead_docx.py`
- 历史参考文件：`E:\BocdWorkingProjects\通知公告\支行发文\正式发文稿\成银行科技〔2025〕14号-成都银行科技支行2024年工作总结和2025年工作计划.docx`

用户反馈的关键问题：

> “你的格式设置仍然不对，最后末尾应该是这样的，检索一下原来的.docx发文稿格式”

用户截图显示，末尾版记应为两行横线表格式版记，而不是普通正文段落。

## 三、失败表现

初版 DOCX 生成时，脚本曾将 Markdown 表格行整体跳过，导致联系人和印发单位没有进入 DOCX。

第一次修复后，脚本把 Markdown 表格中的内容写成普通正文段落：

```text
联系人：黄庆 联系电话：028-85335500
成都银行科技支行综合管理部 2026年4月  日印发
（共印1份）
```

该方式虽然保留了文字，但与历史发文稿版记格式不一致。正确结构应是：

- 联系人/联系电话：表格第1行
- 印发单位/印发日期：表格第2行
- 表格只有横线，无左右可见竖线
- `（共印1份）` 在表格之后另起普通段落

## 四、根因

根因不是字体或段落行距单项设置错误，而是**版记结构判断错误**：

1. Markdown 源文档末尾用简化表格保存版记信息。
2. 生成脚本初始逻辑把所有 `|` 开头的 Markdown 表格行视为可跳过内容。
3. 后续修复只把表格单元格内容转成普通正文段落，没有复刻历史 DOCX 中的表格结构。
4. 中文公文版记在历史发文稿中实际是一个特殊表格，不是正文段落。

后续 skill 需要强调：**遇到公文版记、联系人、联系电话、印发单位、共印份数等末尾信息时，不能只做文本保留；必须检查历史稿中的版记结构。**

## 五、历史 DOCX 检索结果

使用 `python-docx` 和 OOXML 检查历史文件：

```text
E:\BocdWorkingProjects\通知公告\支行发文\正式发文稿\成银行科技〔2025〕14号-成都银行科技支行2024年工作总结和2025年工作计划.docx
```

确认结果：

```text
tables: 1
paragraphs: 66
table rows: 2
table cols: 1
row0: 联系人：黄庆                    联系电话：028-85335500
row1: 成都银行科技支行综合管理部         2025年3月4日印发
```

`（共印1份）` 是表格后的普通段落，不属于表格内容。

### 关键 OOXML 参数

历史表格的关键参数如下：

```xml
<w:tblpPr w:leftFromText="180" w:rightFromText="180"
          w:vertAnchor="text" w:horzAnchor="page"
          w:tblpX="1689" w:tblpY="546"/>
<w:tblOverlap w:val="never"/>
<w:tblW w:w="0" w:type="auto"/>
<w:tblInd w:w="0" w:type="dxa"/>
<w:tblBorders>
  <w:top w:val="single" w:sz="12" w:space="0" w:color="auto"/>
</w:tblBorders>
<w:tblLayout w:type="fixed"/>
<w:tblLook w:val="0000" .../>
```

表格网格：

```xml
<w:gridCol w:w="9208"/>
```

单元格宽度：

```xml
<w:tcW w:w="9208" w:type="dxa"/>
```

单元格边框：

```xml
<w:tcBorders>
  <w:top w:val="single" w:sz="12" w:space="0" w:color="auto"/>
  <w:left w:val="nil"/>
  <w:bottom w:val="single" w:sz="12" w:space="0" w:color="auto"/>
  <w:right w:val="nil"/>
</w:tcBorders>
```

单元格段落格式：

```xml
<w:spacing w:line="560" w:lineRule="exact"/>
<w:ind w:rightChars="-106" w:right="-223" w:firstLineChars="50" w:firstLine="160"/>
```

字体：

```xml
<w:rFonts w:ascii="仿宋" w:eastAsia="仿宋" w:hAnsi="仿宋" w:cs="仿宋"/>
<w:sz w:val="32"/>
```

注意：历史版记使用 `仿宋`，不是 `方正仿宋_GBK`。为贴近历史稿，版记表格内字体采用 `仿宋`。

## 六、脚本修复方式

修复文件：

```text
E:\BocdWorkingProjects\.sisyphus\generate_work_summary_redhead_docx.py
```

### 新增/调整的关键函数

```python
def set_attrs(node, attrs):
    for key, value in attrs.items():
        node.set(qn(key), str(value))


def replace_child(parent, tag, attrs=None):
    old = parent.find(qn(tag))
    if old is not None:
        parent.remove(old)
    node = OxmlElement(tag)
    if attrs:
        set_attrs(node, attrs)
    parent.append(node)
    return node
```

用于可靠写入或替换表格 OOXML 节点。

```python
def set_footer_indent(paragraph):
    ppr = paragraph._element.get_or_add_pPr()
    ind = get_or_add(ppr, "w:ind")
    ind.set(qn("w:rightChars"), "-106")
    ind.set(qn("w:right"), "-223")
    ind.set(qn("w:firstLineChars"), "50")
    ind.set(qn("w:firstLine"), "160")
```

用于复刻历史版记单元格段落缩进。

```python
def set_footer_font(run):
    run.font.name = "仿宋"
    run.font.size = Pt(16)
    rpr = run._element.get_or_add_rPr()
    rfonts = rpr.rFonts
    if rfonts is None:
        rfonts = OxmlElement("w:rFonts")
        rpr.insert(0, rfonts)
    for key in ("w:ascii", "w:hAnsi", "w:eastAsia", "w:cs"):
        rfonts.set(qn(key), "仿宋")
```

用于复刻历史版记字体。

```python
def set_footer_cell_borders(cell):
    tcpr = cell._tc.get_or_add_tcPr()
    borders = tcpr.find(qn("w:tcBorders"))
    if borders is not None:
        tcpr.remove(borders)
    borders = OxmlElement("w:tcBorders")
    for side, val in (("top", "single"), ("left", "nil"), ("bottom", "single"), ("right", "nil")):
        border = OxmlElement(f"w:{side}")
        border.set(qn("w:val"), val)
        if val != "nil":
            border.set(qn("w:sz"), "12")
            border.set(qn("w:space"), "0")
            border.set(qn("w:color"), "auto")
        borders.append(border)
    tcpr.append(borders)
    tcw = get_or_add(tcpr, "w:tcW")
    tcw.set(qn("w:w"), "9208")
    tcw.set(qn("w:type"), "dxa")
```

用于实现“只有横线、无左右竖线”的版记表格视觉效果。

```python
def configure_footer_table(table):
    table.autofit = False
    tbl = table._tbl
    tblpr = tbl.tblPr
    replace_child(tblpr, "w:tblpPr", {
        "w:leftFromText": "180",
        "w:rightFromText": "180",
        "w:vertAnchor": "text",
        "w:horzAnchor": "page",
        "w:tblpX": "1689",
        "w:tblpY": "546",
    })
    replace_child(tblpr, "w:tblOverlap", {"w:val": "never"})
    replace_child(tblpr, "w:tblW", {"w:w": "0", "w:type": "auto"})
    replace_child(tblpr, "w:tblInd", {"w:w": "0", "w:type": "dxa"})
    borders = replace_child(tblpr, "w:tblBorders")
    top = OxmlElement("w:top")
    set_attrs(top, {"w:val": "single", "w:sz": "12", "w:space": "0", "w:color": "auto"})
    borders.append(top)
    replace_child(tblpr, "w:tblLayout", {"w:type": "fixed"})
    replace_child(tblpr, "w:tblLook", {
        "w:val": "0000",
        "w:firstRow": "0",
        "w:lastRow": "0",
        "w:firstColumn": "0",
        "w:lastColumn": "0",
        "w:noHBand": "0",
        "w:noVBand": "0",
    })
    if tbl.tblGrid is not None:
        for grid_col in tbl.tblGrid.findall(qn("w:gridCol")):
            grid_col.set(qn("w:w"), "9208")
```

用于复刻历史版记表格定位、固定布局和宽度。

```python
def add_footer_imprint_table(doc, notice_date):
    date_text = re.sub(r"\s+", "", notice_date or "2026年4月3日")
    rows = [
        "联系人：黄庆                    联系电话：028-85335500",
        f"成都银行科技支行综合管理部         {date_text}印发",
    ]
    table = doc.add_table(rows=2, cols=1)
    configure_footer_table(table)
    for row, text in zip(table.rows, rows):
        for cell in row.cells:
            set_footer_cell_borders(cell)
            p = cell.paragraphs[0]
            p.style = doc.styles["Normal"]
            p.alignment = None
            set_spacing(p, 28)
            set_footer_indent(p)
            run = p.add_run(text)
            set_footer_font(run)
```

用于最终生成 2 行 1 列版记表格。

### Markdown 解析逻辑调整

原逻辑会直接跳过或正文写入 `|` 表格行。修复后，遇到联系人或印发单位表格行时只设置 `footer_table_pending = True`，不写正文段落：

```python
if line.startswith("|"):
    cells = [c.strip() for c in line.strip("|").split("|")]
    content = cells[0] if cells else ""
    if content.startswith("---") or content == "":
        continue
    if content.startswith("联系人：") or content.startswith("成都银行科技支行综合管理部"):
        footer_table_pending = True
    continue
```

循环结束后若存在待写版记，则插入表格：

```python
if footer_table_pending:
    add_footer_imprint_table(doc, notice_date)
```

## 七、验证结果

脚本检查：

```text
python -m py_compile E:\BocdWorkingProjects\.sisyphus\generate_work_summary_redhead_docx.py
LSP diagnostics: No diagnostics found
```

重新生成：

```text
python E:\BocdWorkingProjects\.sisyphus\generate_work_summary_redhead_docx.py
```

生成摘要：

```text
output: E:\BocdWorkingProjects\通知公告\支行发文\通知发文拟稿\成银行科技〔2026〕XX号-成都银行科技支行2025年工作总结和2026年工作计划-草稿.docx
paragraphs: 49
firstLineChars_200: 39
firstLine_attr: 2
exact_spacing_paragraphs: 51
bad_spacing_flags: 0
eastAsia_missing_runs: 0
red_bottom_border: True
page_break_before_main_title: True
fonts_seen: {'方正小标宋_GBK': True, '方正仿宋_GBK': True, '方正黑体_GBK': True, '方正楷体_GBK': True}
```

结构验证：

```text
tables: 1
paras: 49
TABLE 0 rows 2 cols 1 autofit False alignment None
row 0: 联系人：黄庆                    联系电话：028-85335500
row 1: 成都银行科技支行综合管理部         2026年4月3日印发
```

文档末尾 XML 顺序验证：

```text
... 正文最后一段
tbl: 联系人：黄庆 ... 联系电话 ... 成都银行科技支行综合管理部 ... 2026年4月3日印发
p: （共印1份）
sectPr
```

结论：当前 DOCX 已按历史发文稿结构生成版记表格，`（共印1份）` 已位于表格之后。

## 八、建议沉淀到 skill 的规则

### 1. 版记必须作为独立结构处理

当 Markdown 或正文中出现以下内容时，应触发“版记结构处理”而不是正文段落处理：

- `联系人：`
- `联系电话：`
- `综合管理部`
- `印发`
- `（共印...份）`

建议规则：

> 中文公文末尾版记如有历史 DOCX 参考，必须先检查历史 DOCX 中版记是表格、段落边框、文本框还是制表位；不得仅按普通正文段落写入。

### 2. 历史 DOCX 优先于视觉猜测

图片只能说明视觉目标，不能说明 Word 内部结构。应优先使用：

- `python-docx` 检查表格数量、行列数、单元格内容。
- OOXML 检查 `tblPr`、`tcBorders`、`tblGrid`、`w:spacing`、`w:rFonts`。
- 文档 body 顺序检查确认表格与 `（共印1份）` 的先后关系。

### 3. 验证不应只看“文字存在”

本次第一次修复失败，就是因为只验证了联系人和印发单位文字存在，没有验证结构。

skill 应要求至少验证：

- 表格数量是否符合历史稿。
- 表格行列数是否符合历史稿。
- 单元格内容是否符合历史稿。
- `（共印1份）` 是否位于表格之后。
- 横线/竖线是否通过 `tcBorders` 正确设置。
- 字体、字号、行距是否写入 OOXML。

### 4. 版记字体可能不同于正文主字体

正文通常使用 `方正仿宋_GBK`，但历史版记表格内使用 `仿宋`。如果目标是仿历史稿，应优先复刻历史稿字体，而不是机械套用全局正文样式。

### 5. Markdown 表格不能简单跳过

公文生成脚本中遇到 Markdown 表格时，要判断表格内容类型：

| 表格内容 | 建议处理 |
|---|---|
| 联系人/联系电话/印发单位 | 转为版记表格 |
| 正文业务表格 | 转为 Word 表格 |
| 空表格或分隔线 | 跳过 |
| 未识别表格 | 保守保留或提示检查 |

## 九、可加入 skill 的测试场景

### 场景 1：末尾版记被普通段落写入

输入 Markdown：

```markdown
|  |
| --- |
| 联系人：黄庆 联系电话：028-85335500 |
| 成都银行科技支行综合管理部 2026年4月3日印发 |
| （共印1份） |
```

期望输出：

- 联系人/联系电话和印发单位/印发日期进入 2 行 1 列版记表格。
- `（共印1份）` 是表格之后的普通段落。
- 不得把所有行写成普通正文段落。

### 场景 2：历史 DOCX 存在版记表格

给定历史 DOCX，应先抽取并复刻：

- `tables` 数量
- 版记表格行列数
- `tblGrid`
- `tcBorders`
- `w:rFonts`
- `w:spacing`
- 表格在 body 中的位置

成功标准：生成 DOCX 的末尾结构与历史 DOCX 匹配。

### 场景 3：仅文字验证不足

反例：生成文档中能找到 `联系人：黄庆`，但该文字位于普通段落。

应判定为失败，因为结构不符合历史发文稿。

## 十、后续 skill 修改建议

建议在 `office-docs-writer` 或 `docx` skill 中增加一节：

```markdown
## 中文公文版记处理

当目标文档包含联系人、联系电话、印发单位、印发日期、共印份数时，不要默认写成正文段落。必须先检查历史 DOCX 或模板中的真实结构。

检查顺序：
1. 用 python-docx 查看 tables 数量、末尾段落、表格行列和单元格内容。
2. 用 OOXML 查看 tblPr、tblGrid、tcBorders、spacing、rFonts。
3. 复刻历史稿结构：表格、段落边框、制表位或文本框。
4. 生成后验证结构，而不仅验证文字。

失败信号：联系人/印发单位出现在普通正文段落中，而历史稿使用版记表格。
```

建议将“版记结构验证”加入 DOCX 输出验收清单：

- [ ] 版记结构已与历史 DOCX 或模板一致。
- [ ] 联系人/联系电话位于正确结构中。
- [ ] 印发单位/印发日期位于正确结构中。
- [ ] `（共印1份）` 位于表格之后。
- [ ] 表格横线、左右无边框、字体、字号、行距已通过 OOXML 验证。

## 十一、注意事项

1. 不要只根据截图推断 Word 结构；截图无法区分表格、段落边框、制表位、文本框。
2. 不要用“文字已写入”替代“格式已正确”。
3. 不要把正文全局字体规则机械套到版记；版记可能有历史模板字体。
4. 不要把 Markdown 表格统一跳过；末尾版记常用 Markdown 表格保存。
5. 若用户说“检索原来的 DOCX 格式”，必须优先读取历史 DOCX 内部结构，而不是凭经验重写。

## 十二、当前状态

- `generate_work_summary_redhead_docx.py` 已修复。
- 当前目标 DOCX 已重新生成。
- 已验证存在 1 个末尾版记表格，2 行 1 列。
- 已验证 `（共印1份）` 位于表格之后。
- 仍建议用户在 Microsoft Word 中进行最终视觉验收，重点查看横线长度、左右位置和日期空格显示。
