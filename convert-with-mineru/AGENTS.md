# convert-with-mineru — MineU 文档转换技能

## 概述

把 MineU 作为本地文档转换主路径（统一走精准模式 Precision API），配合分流路由和 fallback。

核心原则：
- `.docx` / 数字导出 PDF → MineU 精准模式
- `xls/xlsx` → fallback（精准 API 不支持 Excel）
- 扫描 PDF / 图片 → `multimodal-looker`（如已安装）
- `csv/tsv/json/xml/epub/zip` → `markdown-converter` 或其他 skill
- 输出必须按源文件名命名，不暴露 `full.md`

## 架构

```
scripts/
├── mineru_convert.py       ← CLI 入口 (python -m scripts.mineru_convert)
│   ├── build_parser()      ← argparse: inputs, --recursive, --require-json, --output-root, --config
│   ├── default_output_root()  ← 输出目录推断逻辑
│   └── print_fallback_guidance()  ← 不支持的文件类型提示
├── mineru_config.py        ← 配置加载
│   ├── Settings (dataclass)   ← token, default_output_root, keep_raw_tree
│   ├── load_settings()        ← 优先级: --config > MINERU_TOKEN env > mineru.env > mineru.json
│   ├── _load_env_file()       ← .env 解析
│   └── _load_json_file()      ← .json 解析
├── mineru_inputs.py        ← 输入发现与路由
│   ├── MINEU_EXTENSIONS       ← MineU 支持的后缀集
│   ├── EXCEL_EXTENSIONS       ← Excel 后缀 → fallback
│   ├── FALLBACK_EXTENSIONS    ← 不支持的 → fallback
│   ├── MULTIMODAL_EXTENSIONS  ← 图片/扫描 → multimodal-looker
│   ├── discover_inputs()      ← 文件/目录递归发现
│   ├── split_supported_and_fallback()  ← 按后缀分流
│   ├── is_probably_digital_pdf()       ← PDF 文本/图片探针
│   ├── route_file()                    ← 单文件路由决策
│   └── split_routed_inputs()           ← 批量路由，返回三类: mineu/multimodal/fallback
├── mineru_outputs.py       ← 输出管理
│   ├── OutputTargets (dataclass)  ← markdown, json_dir, json_files, images_dir, stem
│   ├── _allocate_stem()           ← 重名冲突处理 (__2, __3)
│   ├── build_output_targets()     ← 从源文件构建输出路径
│   ├── write_json_file()          ← JSON 写入
│   └── copy_directory()           ← 目录复制
├── mineru_precision.py     ← MineU 精准模式转换
│   ├── _load_mineru_client()      ← 动态导入 mineru_open_sdk
│   ├── _rewrite_markdown_image_paths()  ← MD 图片路径重写
│   ├── _persist_precision_json_files()  ← JSON 产物持久化
│   ├── persist_precision_result()       ← 单文件完整持久化流程
│   └── convert_files()                  ← 批量转换主循环
└── stage_distribution.py   ← 分发打包
    ├── EXCLUDED_TOP_LEVEL_NAMES  ← 排除 .venv, dist, __pycache__ 等
    ├── should_exclude()          ← 过滤判断
    └── _reset_destination()      ← 目标目录重置（带重试）
```

## 输出契约

- `source.pdf` → `source.md`
- `source.pdf` → `source.json/` (content_list, content_list_v2, layout, model — 仅保存实际产出)
- `source.pdf` → `source.images/`
- 不保留 `source.raw/` 或中间副本
- 重名时用 `__2`, `__3` 后缀

## 测试

```powershell
pytest   # 8 个测试文件，39 个测试函数
```

测试文件：
- `conftest.py` — 共享 fixtures
- `test_config_loading.py` — 配置加载各路径
- `test_input_discovery.py` — 文件发现与排除
- `test_mode_selection.py` — 路由决策（mineu/multimodal/fallback）
- `test_precision_flow.py` — 精准模式转换流程
- `test_lightweight_flow.py` — 轻量模式兼容
- `test_output_mapping.py` — 输出路径映射
- `test_distribution_staging.py` — 分发打包

## 配置

优先级：`--config` 参数 > `MINERU_TOKEN` 环境变量 > `mineru.env` > `mineru.json`

示例：`examples/mineru.env`, `examples/mineru.json`

## 已知问题

- SDK 超时：大文件可能触发 MinerU SDK 超时，重试通常有效
- 乱码 (mojibake)：个别文件编码问题，根因待排查
- PPTX 双路径：当前走 MineU，未来可能增加本地解析

## 常见错误

- 把 ZIP 里的 `full.md` 当最终产物
- `.md` 引用 `images/...` 但图片目录改名为 `source.images/`
- 把所有 JSON 压成单个 `source.json`
- 把 `xls/xlsx` 送进 MineU（应走 fallback）
- 明知是扫描 PDF 还强压给 MineU
