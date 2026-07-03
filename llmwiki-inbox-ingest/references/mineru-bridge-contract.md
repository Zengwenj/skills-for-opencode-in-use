# MinerU Bridge Contract

## 架构原则

PowerShell 脚本不得直接调用 convert-with-mineru。Agent bridge 固定为以下步骤：

1. `prepare-mineru-batch.ps1` 只从 `apply-manifest.jsonl` 中 `committed` 或 `skipped_existing_committed` 的 archive_path 生成 `mineru-batch.json`。
2. 未 committed 的文件不得进入 MinerU batch。
3. agent 读取 `mineru-batch.json`。
4. agent/worker 按 source_id 调用 `convert-with-mineru` 或执行 mock mode。
5. 输出保存到 `run/mineru-output/<source_id>/`。
6. agent 或 mock 写 `parse-manifest.csv` 和必要 failures。
7. `ingest-mineru-output.ps1` 只消费 committed archive provenance 与 parse manifest。

## Capability Matrix

每个扩展名必须声明：`extension`、`supported_for_archive`、`supported_for_mineru`、`mineru_mode`、`reason_if_unsupported`。

| extension | supported_for_archive | supported_for_mineru | mineru_mode | reason_if_unsupported |
| --- | --- | --- | --- | --- |
| `.pdf` | true | true | `convert_with_mineru` | |
| `.doc` | true | conditional | `token_or_env_detected` | Flash mode may not support .doc; require environment capability check |
| `.docx` | true | true | `convert_with_mineru` | |
| `.ppt` | true | conditional | `token_or_env_detected` | Flash mode may not support .ppt; require environment capability check |
| `.pptx` | true | true | `convert_with_mineru` | |
| `.xls` | true | true | `convert_with_mineru` | |
| `.xlsx` | true | true | `convert_with_mineru` | |
| `.png` | true | true | `convert_with_mineru` | |
| `.jpg` | true | true | `convert_with_mineru` | |
| `.jpeg` | true | true | `convert_with_mineru` | |
| `.jp2` | true | true | `convert_with_mineru` | |
| `.webp` | true | true | `convert_with_mineru` | |
| `.gif` | true | true | `convert_with_mineru` | |
| `.bmp` | true | true | `convert_with_mineru` | |
| `.html` | true | conditional | `convert_with_mineru_html` | Only supported when routed as HTML page/model and environment confirms |
| `.htm` | true | conditional | `convert_with_mineru_html` | Only supported when routed as HTML page/model and environment confirms |

不在矩阵内的扩展名默认 `supported_for_archive=false`、`supported_for_mineru=false`，除非 config 明确 allowlist 且 references 更新。

### mineru_mode 说明

| mode | 含义 |
| --- | --- |
| `convert_with_mineru` | 非 HTML 文档，通过 convert-with-mineru 精确模式（vlm）处理 |
| `convert_with_mineru_html` | HTML/HTM 文档，通过 convert-with-mineru MinerU-HTML 模式处理 |
| `token_or_env_detected` | 需要检测环境是否支持（如旧 .doc/.ppt 格式，环境支持则尝试 convert_with_mineru，否则跳过） |
| `mock` | 仅用于 fixture 测试，不调真实 MinerU |
| `skip_unsupported` | 不支持，批次中跳过 |

## Committed-Only Batch 规则

- `mineru-batch.json` 的 `items` 数组只能包含在 `apply-manifest.jsonl` 中状态为 `committed` 或 `skipped_existing_committed` 的文件。
- 状态为 `planned`、`copied_temp`、`failed` 等的文件不得进入批次。
- 批次中每个 item 的 `archive_path` 和 `archive_sha256` 必须与 apply-manifest 中一致。

## Agent Bridge 步骤

agent 处理 MinerU batch 的流程：

1. 读取 run 目录中的 `mineru-batch.json`。
2. 遍历 `items` 数组，按 `mineru_route` 决定处理方式：
   - `convert_with_mineru` → 调用 `convert-with-mineru`（精确模式/vlm）。
   - `convert_with_mineru_html` → 调用 `convert-with-mineru`（MinerU-HTML 模式）。
   - `token_or_env_detected` → 检测环境，支持则调用 convert-with-mineru，否则标记 `skipped`。
   - `mock` → 使用预置 fixture markdown 输出。
   - `skip_unsupported` → 标记 `skipped`，记录原因。
3. 输出保存到 `{output_dir}/{source_id}.md`（即 `run/mineru-output/<source_id>/<source_id>.md`）。
4. 为每个 item 写 `parse-manifest.csv` 对应行。
5. 失败的 item 写入 `failures.csv`。

## MinerU Output 路径

```
run/mineru-output/<source_id>/<source_id>.md
run/mineru-output/<source_id>/<source_id>.images/  (如有图片)
```

`<source_id>` 为 inventory 中的 source_id。图片目录由 convert-with-mineru 原样输出（`<original_stem>.images/`），bridge 负责将其映射为 `<source_id>.images/`，Markdown 内图片引用相应重写。

## Mock Mode

mock mode 用于 fixture 测试，不调用 MCP：

- 正常 markdown（写入 `<source_id>.md`）进入 raw。
- 坏 markdown（无 heading、字节数 < 500、含错误占位）进入 failures。
- raw collision 使用 suffix。
- source_id mismatch 进入 failures。

mock mode 通过 `mineru-batch.json` 中 `mineru_route: "mock"` 触发。mock markdown 写入 `run/mineru-output/<source_id>/<source_id>.md`。
