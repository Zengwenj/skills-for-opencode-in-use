# 格式规范

## 页面版式

### 普通页面版式（默认）

适用于：内部文件、工作报告、总结、简报、学习记录等一般性文档。

| 参数 | 值 |
|------|-----|
| 纸张 | A4 |
| 上边距 | 2.54 cm |
| 下边距 | 2.54 cm |
| 左边距 | 3.18 cm |
| 右边距 | 3.18 cm |
| 页眉边距 | 1.50 cm |
| 页脚边距 | 1.75 cm |
| 每页行列 | 不限定（根据内容自然排版） |

### 公文页面版式（备选）

适用于：需严格符合国家公文格式标准的正式行文、请示、通知等。
用户明确要求时使用。
红头仅在文种规范要求设置，或用户明确要求设置红头时启用。

| 参数 | 值 |
|------|-----|
| 纸张 | A4 |
| 上边距 | 37 mm |
| 下边距 | 35 mm |
| 左边距 | 28 mm |
| 右边距 | 26 mm |
| 页眉边距 | 15 mm |
| 页脚边距 | 17.5 mm |
| 版心尺寸 | 156 mm × 225 mm |
| 每页行列 | 22 行 × 28 字（推荐版式设置，不要求程序绝对实现网格物理对齐） |

## 行距规范

| 元素 | 行距类型 | 行距值 |
|------|---------|--------|
| 标题 | 固定值 | 40 磅 |
| 正文 | 固定值 | 28 磅 |
| 首行缩进 | — | 2 字符 |

> 正文行距为 **28 磅**，非 30 磅。

## 字体规范

### 标题层级

| 层级 | 编号格式 | 字体 | 字号 | 加粗 | 大纲级别 | 对齐 | 行距 |
|------|---------|------|------|------|---------|------|------|
| 文档主标题 | — | 方正小标宋_GBK | 二号 | 否 | 无 | 居中 | 40磅 |
| 一级标题 | 一、 | 方正黑体_GBK | 三号 | 否 | 1级 | 左对齐 | 40磅 |
| 二级标题 | （一） | 方正楷体_GBK | 三号 | 否 | 2级 | 左对齐 | 40磅 |
| 三级标题 | 1. | 方正仿宋_GBK | 三号 | 否 | 3级 | 左对齐 | 40磅 |
| 四级标题 | （1） | 方正仿宋_GBK | 三号 | 否 | 4级 | 左对齐 | 40磅 |
| 正文 | — | 方正仿宋_GBK | 三号 | 否 | 正文 | 两端对齐 | 28磅 |

### 大纲级别设置

在 Word 文档中，标题必须设置对应的大纲级别：

- **一级标题**：大纲级别 1级（对应 Word 样式 Heading 1）
- **二级标题**：大纲级别 2级（对应 Word 样式 Heading 2）
- **三级标题**：大纲级别 3级（对应 Word 样式 Heading 3）
- **四级标题**：大纲级别 4级（对应 Word 样式 Heading 4）
- **正文**：大纲级别 正文（无大纲级别或 Body Text）

### 数字与字母

正文中出现的**数字与英文字母统一使用 Times New Roman**。

### 字体安装前置检查

- 若目标输出为 `.docx`，必须先检查目标中文字体是否已安装
- 若 `方正小标宋_GBK`、`方正仿宋_GBK`、`方正黑体_GBK`、`方正楷体_GBK` 中任一未安装，必须显式说明回退风险
- 未经验证，不得把“XML 已写入目标字体名”表述为“Word 最终显示必然正确”

### 字体缺失时的回退策略

- 首选目标字体仍为：方正小标宋_GBK、方正仿宋_GBK、方正黑体_GBK、方正楷体_GBK
- 若目标字体未安装，输出必须标注为“存在字体回退风险”，不得表述为“已完全符合指定字体规范”
- 未经用户确认或运行环境约定，不预设某一替代字体等同于目标字体
- 如因交付需要必须使用替代字体，应在输出说明中明确写出“目标字体 / 实际替代字体 / 风险说明”
- 可根据本机字体环境选择接近字体作临时替代，但该行为仅代表可读性回退，不代表已满足指定字体验收要求

### 标点符号

- **引号**：默认使用**中文引号**（"" 和 ''）
- 除非用户特殊说明，否则不使用英文引号 ("" 和 '')
- 其他标点符号遵循中文公文规范

## 版式选择规则

1. 默认使用**普通页面版式**
2. 如用户在 prompt 中注明"公文格式"或"标准公文版式"，改用公文页面版式
3. 红头不是默认项；只有文种规范要求红头，或用户明确要求设置红头时，才启用红头版头结构
4. 不在每次调用时要求用户重复指定格式参数

## 红头与版头结构（按需启用）

仅当文种规范明确要求红头，或用户命令中明确要求设置红头时，才启用以下规则；否则保持普通标题结构，不默认添加红头、发文字号或红色分隔线。

### 国标可援引要点

- 发文机关标志居中排布
- 发文机关标志上边缘至版心上边缘 35mm
- 红色分隔线位于发文字号下 4mm 处，且与版心等宽
- 主标题位于红色分隔线下空二行

### 本项目采用规范（启用红头时）

- **发文机关**：居中排布；上边缘至版心上边缘 35mm；字体 `方正小标宋_GBK`；字号 72号；颜色红色
- **发文字号**：如文种需要发文字号，则按公文版头结构放置于发文机关下方
- **红色分隔线**：位于发文字号下 4mm 处；如无发文字号，则位于发文机关下 4mm 处；为与版心等宽的红色直线段
- **主标题**：位于红色分隔线下空二行

## 段落规范

- **首行缩进**：2 字符（必须使用 XML 属性 `w:firstLineChars`；禁止用厘米、磅值、twips 或其他物理长度近似，参见下方技术实现）
- **标题缩进**：1-4级标题均需设置首行缩进2字符
- **主标题缩进**：文档主标题由于要求居中对齐，**绝对禁止添加首行缩进**，以防止视觉失衡偏移。
- **正文缩进**：首行缩进2字符
- **段落间距**：**段前0行，段后0行**（必须显式设置，不能为None）
- 列举项可使用"一、二、三"或"（一）（二）（三）"层级编号
- 避免使用 Markdown 格式符号（如 `#`、`**`、`-`）出现在最终文档输出中

## 标题样式映射规则

- 匹配 `^一、|^二、|^三、|^四、|^五、|^六、|^七、|^八、|^九、|^十、` 的段落，必须映射为**一级标题**，对应 Heading 1 或等效 `w:outlineLvl=0`
- 匹配 `^（一）|^（二）|^（三）|^（四）|^（五）|^（六）|^（七）|^（八）|^（九）|^（十）` 的段落，必须映射为**二级标题**，对应 Heading 2 或等效 `w:outlineLvl=1`
- 匹配 `^1\.|^2\.|^3\.|^4\.|^5\.` 的段落，必须映射为**三级标题**，对应 Heading 3 或等效 `w:outlineLvl=2`
- 匹配 `^（1）|^（2）|^（3）|^（4）|^（5）` 的段落，必须映射为**四级标题**，对应 Heading 4 或等效 `w:outlineLvl=3`
- 禁止把标题编号段落重写为正文样式（如 Body Text、正文、`CC_Body` 等）
- 若使用自定义样式，必须显式补齐等效 `w:outlineLvl`，不能只改样式名

## 字体颜色与字形

- **颜色**：所有文字必须为纯黑色 **RGB(0, 0, 0)**
- **字形**：**常规**（非粗体、非斜体、无下划线）
- **标题字形**：主标题、1-4级标题及正文均保持常规字形（除非用户特殊要求加粗）

## 技术实现参考

### Python-docx 完整代码示例

```python
from docx import Document
from docx.shared import Pt, RGBColor, Mm
from docx.oxml.ns import qn
import docx.oxml

def set_first_line_chars(paragraph, chars=2):
    """
    设置首行缩进为指定字符数（让Word显示为'首行缩进 2字符'而非厘米值）
    修复点：利用原生 first_line_indent 先生成 w:ind，保证其在 OOXML schema 中的严格顺序（必须在 w:jc 对齐标签之前），
    避免直接 append 导致标签乱序而被 Word 丢弃。
    """
    from docx.shared import Pt
    paragraph.paragraph_format.first_line_indent = Pt(1) # 占位，触发按正确顺序插入 w:ind
    pPr = paragraph._element.get_or_add_pPr()
    ind = pPr.find(qn('w:ind'))
    ind.set(qn('w:firstLineChars'), str(int(chars * 100)))
    ind.attrib.pop(qn('w:firstLine'), None) # 移除多余的物理宽度参数

def set_run_font(run, cn_font_name, font_size, en_font_name='Times New Roman', bold=False, color=RGBColor(0,0,0)):
    """设置字体，区分中英文字体，并确保颜色为纯黑色，字形为常规"""
    run.font.name = en_font_name  # 控制西文与数字字体
    run._element.rPr.rFonts.set(qn('w:eastAsia'), cn_font_name) # 控制中文字体
    run.font.size = Pt(font_size)
    run.font.bold = bold
    run.font.color.rgb = color  # 纯黑色 RGB(0,0,0)
    run.font.italic = False     # 确保不是斜体
    run.font.underline = False  # 确保无下划线

def set_paragraph_spacing(para, space_before=0, space_after=0, line_spacing=28):
    """设置段落间距和行距 - 必须显式设置为0，不能为None"""
    para.paragraph_format.space_before = Pt(space_before)  # 段前0行
    para.paragraph_format.space_after = Pt(space_after)    # 段后0行
    para.paragraph_format.line_spacing = Pt(line_spacing)

# ===== 创建文档示例 =====
doc = Document()

# 设置公文页面版式
sections = doc.sections[0]
sections.top_margin = Mm(37)
sections.bottom_margin = Mm(35)
sections.left_margin = Mm(28)
sections.right_margin = Mm(26)

# 一级标题（方正黑体_GBK，三号，大纲级别1级，首行缩进2字符，段前段后0行）
h1 = doc.add_paragraph()
h1.style = doc.styles['Heading 1']  # 设置大纲级别1级
h1_run = h1.add_run('一、工作概述')
set_run_font(h1_run, '方正黑体_GBK', 16, en_font_name='Times New Roman', bold=False)
set_paragraph_spacing(h1, space_before=0, space_after=0, line_spacing=40)
set_first_line_chars(h1, 2)  # 首行缩进2字符

# 正文段落（方正仿宋_GBK，三号，行距28磅，首行缩进2字符，段前段后0行）
p1 = doc.add_paragraph()
p1_run = p1.add_run('为深入贯彻...')
set_run_font(p1_run, '方正仿宋_GBK', 16, en_font_name='Times New Roman')
set_paragraph_spacing(p1, space_before=0, space_after=0, line_spacing=28)
set_first_line_chars(p1, 2)  # 首行缩进2字符
```

### 字号对应表

| 字号 | 磅值 (Pt) |
|------|----------|
| 二号 | 22 |
| 三号 | 16 |
| 四号 | 14 |

### 关键说明

**首行缩进**：
- ❌ 错误：`paragraph_format.first_line_indent = Pt(24)` —— Word会显示为"0.85cm"
- ❌ 错误：设置 `w:firstLine='480'` 或任何 cm/twips 近似值 —— 这是物理长度，不是字符语义
- ✅ 正确：只使用 `w:firstLineChars` XML属性（2字符 = `200`）—— Word会显示为"2字符"
- **说明**：`w:firstLineChars` 与 `w:firstLine` 是不同的 OOXML 属性；当要求是“首行缩进 2字符”时，不能把字符单位降级为物理长度近似值。

**段落间距**：
- ❌ 错误：`space_before = None` —— 表示继承样式，不是0行
- ✅ 正确：`space_before = Pt(0)` —— 明确表示段前0行

**字体颜色**：
- ❌ 错误：不设置 color.rgb —— 可能继承主题颜色
- ✅ 正确：`run.font.color.rgb = RGBColor(0, 0, 0)` —— 纯黑色

**DOCX 结果验收**：
- ✅ 中文字体必须核对 `w:eastAsia`
- ✅ 首行缩进必须核对 `w:firstLineChars="200"`
- ✅ 标题层级必须核对 Heading 1/2/3/4 或等效 `w:outlineLvl`
- ❌ 错误：只看视觉上像标题/像缩进，就认定 DOCX 已符合规范
