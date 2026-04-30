# 历史 DOCX 检索与复刻协议

## 适用范围

本协议在以下任一条件满足时触发：

- 用户提供了历史 `.docx` 文件路径，要求模仿其版式（特别是版记/落款区域）。
- 当前文档类型为**红头公文**或**带版记公文**（如正式发文、请示、通知），且用户期望保留出版级格式一致性。
- 用户明确指令"检索原来的 DOCX 格式"或"按历史稿版式输出"。

## 不适用范围

本协议不适用于以下场景：

- 无历史稿、且文档类型为**非红头/非版记**的内部文件（如学习记录、会议记录、工作简报——这些类型的版记非必须，不应强行添加）。
- 输出目标为**纯文本**（如 Markdown 或纯 TXT），无需 DOCX 内部结构。
- 用户明确要求用新模板而非历史稿。

在这些场景中，跳过本协议，直接使用默认模板或用户提供的模板。

---

## 四步检查协议

当用户提供历史 `.docx` 文件路径时，必须按以下顺序逐项检查。每步给出可执行的最小代码片段。

### 步骤1：python-docx 结构检查

**目的**：快速确认文档中表格的数量、行列数、单元格文本内容，以及段落总数和末尾关键段落的位置。

**最小可执行命令**：

```python
from docx import Document

# 替换为实际历史文件路径
doc = Document("历史文件.docx")

# 表格概览
print(f"表格数量: {len(doc.tables)}")
print(f"段落数量: {len(doc.paragraphs)}")

for i, table in enumerate(doc.tables):
    print(f"\nTABLE {i}: {len(table.rows)} 行 × {len(table.columns)} 列")
    for j, row in enumerate(table.rows):
        cells = [cell.text.strip() for cell in row.cells]
        print(f"  row {j}: {' | '.join(cells)}")

# 末尾5段（辅助判断版记表格与后续段落的顺序）
print("\n末尾5个段落:")
for p in doc.paragraphs[-5:]:
    text = p.text.strip()
    if text:
        print(f"  [{p.style.name}] {text}")
```

**检查要点**：

- 版记表格通常是文档的**唯一表格**或**最后一个表格**。
- 关键段落如"（共印X份）"通常**在表格之后**而非表格内部。
- 如果不确定某段落是否属于某个表格单元格，查看 python-docx 输出中该段落属于 table.cells 的 `.text` 还是 `doc.paragraphs`。

### 步骤2：OOXML tblPr 提取

**目的**：提取表格级属性——浮动定位、宽度、边框、布局方式。这些属性无法通过 python-docx 高层 API 获取，必须直接读 OOXML。

**最小可执行命令**：

```python
from docx import Document
from lxml import etree

# 替换为实际历史文件路径
doc = Document("历史文件.docx")

for i, table in enumerate(doc.tables):
    tbl = table._element
    tbl_pr = tbl.find("{http://schemas.openxmlformats.org/wordprocessingml/2006/main}tblPr")

    if tbl_pr is None:
        print(f"TABLE {i}: 无 tblPr")
        continue

    print(f"\n=== TABLE {i} tblPr ===")
    print(etree.tostring(tbl_pr, encoding="unicode", pretty_print=True))

    # 单独提取关键属性
    tblpPr = tbl_pr.find("{http://schemas.openxmlformats.org/wordprocessingml/2006/main}tblpPr")
    if tblpPr is not None:
        print(f"  浮动定位: {etree.tostring(tblpPr, encoding='unicode').strip()}")

    tblW = tbl_pr.find("{http://schemas.openxmlformats.org/wordprocessingml/2006/main}tblW")
    if tblW is not None:
        print(f"  表格宽度: w={tblW.get('{http://schemas.openxmlformats.org/wordprocessingml/2006/main}w')} "
              f"type={tblW.get('{http://schemas.openxmlformats.org/wordprocessingml/2006/main}type')}")

    tblBorders = tbl_pr.find("{http://schemas.openxmlformats.org/wordprocessingml/2006/main}tblBorders")
    if tblBorders is not None:
        print(f"  表格边框: {etree.tostring(tblBorders, encoding='unicode').strip()}")

    tblLayout = tbl_pr.find("{http://schemas.openxmlformats.org/wordprocessingml/2006/main}tblLayout")
    if tblLayout is not None:
        print(f"  布局方式: {tblLayout.get('{http://schemas.openxmlformats.org/wordprocessingml/2006/main}type')}")
```

**关键属性说明**：

| 属性 | 含义 | 版记常见值 |
|------|------|-----------|
| `tblpPr` | 表格浮动定位（水平/垂直参照、偏移量） | 以历史稿实测为准：存在 `tblpPr` 时复刻其浮动定位，无 `tblpPr` 时保持内联流 |
| `tblW` | 表格宽度 | `type="auto"` 或 `type="dxa"` |
| `tblBorders` | 表格级边框 | 仅 `top` 为 single（版记上横线），左右下通常无或 nil |
| `tblLayout` | 布局模式 | `type="fixed"`（固定列宽） |
| `gridCol` | 列网格定义 | 单列时宽度等于版心宽度 |

### 步骤3：OOXML tcBorders 提取

**目的**：提取每个单元格的上下左右边框状态。版记表格的典型特征是：每个单元格的 `top` 和 `bottom` 为 single 实线，`left` 和 `right` 为 nil（无线条）。

**最小可执行命令**：

```python
from docx import Document
from lxml import etree

# 替换为实际历史文件路径
doc = Document("历史文件.docx")

NS = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"

for i, table in enumerate(doc.tables):
    print(f"\n=== TABLE {i} 单元格边框 ===")
    for j, row in enumerate(table.rows):
        for k, cell in enumerate(row.cells):
            tc = cell._element
            tc_pr = tc.find(f"{NS}tcPr")
            tc_borders = tc_pr.find(f"{NS}tcBorders") if tc_pr is not None else None

            if tc_borders is not None:
                borders = {}
                for pos in ["top", "bottom", "left", "right"]:
                    b = tc_borders.find(f"{NS}{pos}")
                    if b is not None:
                        borders[pos] = {
                            "val": b.get(f"{NS}val"),
                            "sz": b.get(f"{NS}sz"),
                            "color": b.get(f"{NS}color", "auto")
                        }
                    else:
                        borders[pos] = "未设置"
                print(f"  [{j}][{k}]: {borders}")
            else:
                print(f"  [{j}][{k}]: 无 tcBorders")

    # 同时提取单元格内的字体信息（历史版记可能使用非标准字体）
    print(f"\n=== TABLE {i} 字体 ===")
    for j, row in enumerate(table.rows):
        for k, cell in enumerate(row.cells):
            for para in cell.paragraphs:
                for run in para.runs:
                    rPr = run._element.find(f"{NS}rPr")
                    if rPr is not None:
                        rFonts = rPr.find(f"{NS}rFonts")
                        sz = rPr.find(f"{NS}sz")
                        if rFonts is not None:
                            eastAsia = rFonts.get(f"{NS}eastAsia", "未设置")
                            ascii_font = rFonts.get(f"{NS}ascii", "未设置")
                            print(f"  [{j}][{k}] 字体: eastAsia={eastAsia}, ascii={ascii_font}")
                        if sz is not None:
                            print(f"  [{j}][{k}] 字号: {int(sz.get(f'{NS}val')) / 2}磅")
```

**检查要点**：

- 版记表格的 `tcBorders` 通常 **上下边框有值**（`val="single"`），**左右为 nil**——这是区分"表格"和"装饰线"的关键。
- 历史版记字体可能与正文不同。例如正文用 `方正仿宋_GBK`，但版记表格内用 `仿宋`。不能用全文字体规则机械覆盖版记单元格。
- 字号也需单独确认——版记通常比正文小（如四号 14磅 或小四 12磅）。

### 步骤4：Body 顺序验证

**目的**：确认表格与关键段落（如"共印份数"、"印发日期"等版记辅助信息）的先后关系。这对正确重建版记输出顺序至关重要。

**最小可执行命令**：

```python
from docx import Document
from docx.oxml.ns import qn

# 替换为实际历史文件路径
doc = Document("历史文件.docx")

body = doc.element.body
table_count = 0
para_count = 0

print("Body 元素顺序（末尾15个元素）:")
for idx, child in enumerate(list(body)[-15:]):
    tag = child.tag.split("}")[-1] if "}" in child.tag else child.tag
    if tag == "tbl":
        table_count += 1
        # 获取表格第一行第一列文本作为标识
        first_text = ""
        rows = child.findall(qn("w:tr"))
        if rows:
            first_cell = rows[0].findall(qn("w:tc"))
            if first_cell:
                all_text = first_cell[0].itertext()
                first_text = "".join(all_text)[:80]
        print(f"  [{idx}] TABLE (表格第{table_count}个): {first_text}")

    elif tag == "p":
        para_count += 1
        text = "".join(child.itertext()).strip()
        if text:
            print(f"  [{idx}] PARAGRAPH: {text[:100]}")
    elif tag == "sectPr":
        print(f"  [{idx}] sectPr (节属性)")
    else:
        print(f"  [{idx}] <{tag}>")

# 验证关键关系
print("\n=== 顺序检查 ===")
table_before_print_count = False
for child in list(body):
    tag = child.tag.split("}")[-1] if "}" in child.tag else child.tag
    text = "".join(child.itertext()).strip()

    if tag == "tbl":
        if "共印" in "".join(child.itertext()):
            print("✓ 表格内包含'共印'字样")
    if tag == "p" and "共印" in text:
        # 检查此段落前后是否有表格
        prev_is_table = False
        prev_elem = child.getprevious()
        if prev_elem is not None:
            prev_tag = prev_elem.tag.split("}")[-1] if "}" in prev_elem.tag else prev_elem.tag
            prev_is_table = (prev_tag == "tbl")

        if prev_is_table:
            print("✓ （共印X份）段落紧跟在表格之后——符合历史稿结构")
        else:
            print("⚠ （共印X份）段落不在表格之后——结构可能与历史稿不同")
```

**检查要点**：

- 在正式公文版记中，典型顺序是：`……正文最后一段 → 版记表格 → （共印X份）段落 → sectPr（节属性）`。
- （共印X份）段落**应不在表格内**，是独立的 `w:p` 元素。
- 如果（共印X份）在表格内部或表格之前，说明目标文档的版记结构与默认模板不同，需以历史稿为准。

---

## 无历史稿时的处理路径

在没有历史 `.docx` 文件作为参考的情况下，**禁止凭经验兜底**生成版记结构。

必须执行以下步骤：

1. **显式报告风险**：在输出中向用户报告以下风险信息：
   > "⚠ 无参考稿，版记结构将使用参考模板（2行1列，表格级顶线+单元格横线，无左右竖线；字体字号为示例值，须经用户确认后使用）。实际历史稿可能存在格式偏差，包括但不限于：表格行列数不同、边框样式差异、段落顺序调整、字体字号不一致。"

2. **请求用户确认**：给出两个选项：
   - A：同意使用默认模板，接受可能的格式偏差。
   - B：提供历史 `.docx` 文件路径，我将先检索其内部结构再生成精确复刻。

3. **等待用户选择**：在获得用户明确选择前，不得执行版记写入。

4. **不得做的行为**：
   - ❌ 凭经验"版记就是2行1列上横线"直接生成
   - ❌ 凭截图或用户口头描述推断 Word 内部结构
   - ❌ 用"文字已写入"替代"格式已正确"作为交付标准

---

## 历史稿为 .doc 格式时的处理

`python-docx` 不支持 `.doc`（旧版 Word 二进制格式，Word 97-2003）。

遇到 `.doc` 格式的历史稿时：

1. 告知用户：`python-docx` 无法读取 `.doc` 格式，需先转换为 `.docx`。
2. 建议用户在 Word 中打开 `.doc` 文件，"另存为" → 选择 `.docx` 格式。
3. 转换完成后再按本协议的四步检查流程执行。
4. 注意：转换过程中部分 OOXML 属性可能发生细微变化（如 `tblpPr` 定位值），在复刻时应以转换后的 `.docx` 为准，并在输出中标注"基于 .doc → .docx 转换稿"。

---

## 失败信号

以下行为视为协议执行失败，需回退修正：

| 失败信号 | 说明 |
|----------|------|
| 未检查历史稿就写入版记 | 本协议未触发或跳过，版记结构完全来自默认模板 |
| 凭截图推断 Word 结构 | 截图无法区分表格、段落边框、制表位、文本框 |
| 只用文字验证代替结构验证 | "肉眼看起来没问题" ≠ OOXML 结构正确 |
| 把正文全局字体规则机械套到版记 | 版记单元格字体可能与正文不同（如正文用方正仿宋_GBK，版记用仿宋） |
| 未检查 body 顺序就确定表格与段落关系 | （共印X份）的位置错误会导致版记结构整体偏移 |
| 无历史稿时凭经验兜底 | 在用户未确认的情况下默认生成版记 |
