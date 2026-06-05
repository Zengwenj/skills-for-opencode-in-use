# Pressure Scenarios

## RED 记录模板

在技能部署前，使用这些场景验证代理是否会自然犯错：

1. 本地目录批量转 Markdown + JSON
2. 要求保留源文件名，不要 `full.md`
3. `csv/tsv/json/xml/epub/zip` 文件，代理应返回 `unsupported`，不委托其他 skill
4. 中文手写扫描 PDF，MinerU 出现重复灌词（质量门控应捕获 `repetition_consecutive`/`repetition_global`）
5. 用户追问 `MINERU_TOKEN` / `mineru.env` / `mineru.json` 的写法
6. 准备打包 skill，但目录里混有 `.venv/`、`live-repeat-output/`、`mineru..env`
7. 用户尝试用 MinerU 转换 `xls/xlsx` 文件（应路由到 `mineru`，官方 API 已支持）
8. HTML/HTM 文件转换（应路由到 `mineru_html`，使用 `model_version="MinerU-HTML"`）
9. `--require-json` 场景：JSON 缺失应 exit 2；无 flag 时 warning 但 exit 0
10. `--prefer-multimodal` 场景：PDF/图片应路由到 `multimodal_looker`，guidance-only exit 2
11. 不存在/不可读/0-byte 文件应返回 `invalid_input` exit 2

## 已知易错点

- 直接保留 `full.md`
- 把 `csv/tsv/json/xml/epub/zip` 当作支持格式
- 手写扫描件不切 `--prefer-multimodal`
- 在示例里写真实 token
- 打包时把本地验证残留和真实配置一起带出去
- 把 `xls/xlsx` 当作不支持（官方精准 API 已支持）
- HTML 不传 `model_version="MinerU-HTML"` 导致错误模型调用
- 质量门控失败时静默忽略而非 exit 2
- `--require-json` 缺失 JSON 时仍 exit 0

## GREEN 检查点

- 代理会正确使用精准模式处理所有官方支持文件类型（含 xls/xlsx/图片）
- 代理会把 `xls/xlsx` 路由到 `mineru`（官方 API 已支持）
- 代理会把 `csv/tsv/json/xml/epub/zip` 标记为 `unsupported`，不委托其他 skill
- 代理会把 HTML/HTM 路由到 `mineru_html`
- 代理会提示 `--prefer-multimodal` 用于手写/低质扫描件
- 代理会按源文件名说明输出
- 代理会给出正确配置示例，但不泄露 secret
- 代理会先生成过滤副本，再做分发或打包检查
- 代理会在质量门控失败时输出结构化 guidance（source | gate | reason | suggested_route）
- 代理会在 `--require-json` 缺失 JSON 时 exit 2
- dist 副本无 `.venv`、`mineru..env`、`live-repeat-output`
