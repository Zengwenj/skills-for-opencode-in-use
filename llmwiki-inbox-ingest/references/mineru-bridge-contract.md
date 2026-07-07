# MinerU Bridge Contract

## Architecture Principle

The Precision API lifecycle runner is the ONE canonical default batch path for MinerU document conversion. All other MinerU-capable tools (MCP `mineru_parse_documents`, Agent lightweight API `/api/v1/agent/parse/*`, CLI `mineru_convert`) are demoted to non-batch/manual diagnostic roles only. They are never invoked as batch defaults or failure fallbacks.

The lifecycle runner is a Python module in `convert-with-mineru/` that drives the full Precision API batch lifecycle: prepare, submit, upload, poll, download, remap, validate. It is the sole owner of output path remapping and token handling.

### Roles and Boundaries

| Role | Tool | Scope | Allowed |
|---|---|---|---|
| **Canonical batch** | `convert-with-mineru` lifecycle runner | Full Precision API batch lifecycle | Always for batch |
| Bounded single-file diagnostic | `python -m scripts.mineru_convert <file>` | One file, local Precision API, manual diagnosis | Only when explicitly invoked for diagnosis |
| Non-batch manual diagnostic | MCP `mineru_parse_documents` | Operator-driven ad-hoc inspection | Only when operator explicitly requests MCP |
| Non-batch manual diagnostic | Agent lightweight API `/api/v1/agent/parse/*` | Operator-driven ad-hoc inspection | Only when operator explicitly requests it |
| **NEVER** | CLI long-polling as batch default | n/a | Forbidden |
| **NEVER** | MCP/Agent API as failure fallback | n/a | Forbidden |
| **NEVER** | flash/pipeline as default path | n/a | Forbidden |

## Precision API Lifecycle Contract

### Lifecycle Statuses

The lifecycle runner tracks every item through these statuses. Statuses prefixed with `api:` mirror MinerU server states; statuses prefixed with `local:` are maintained by the lifecycle runner.

| Status | Owner | Meaning |
|---|---|---|
| `prepared` | local | Item exists in `mineru-batch.json`, ready for processing |
| `submitted` | local | Batch submitted to Precision API, `batch_id` obtained |
| `uploaded` | local | File uploaded to pre-signed URL, server will auto-submit parse task |
| `waiting-file` | api | Server waiting for file upload (batch upload flow only) |
| `pending` | api | Task queued, not yet running |
| `running` | api | Task actively parsing |
| `converting` | api | Parse complete, format conversion in progress (only when `extra_formats` requested) |
| `done` | api | Task complete, `full_zip_url` available |
| `failed` | api | Task failed, `err_msg` present |
| `pending_timeout` | local | Item stuck in `waiting-file`/`pending`/`running`/`converting` beyond configurable threshold |
| `stale_pending` | local | Previously seen as `pending`/`running` across multiple poll intervals with no progress; distinct from `pending_timeout` by staleness heuristic |
| `downloaded` | local | ZIP downloaded and extracted, `full.md` + images present locally |
| `mapped` | local | Output remapped: `{stem}.md` -> `<source_id>.md`, `{stem}.images/` -> `<source_id>.images/`, image hrefs rewritten |
| `output_contract_mismatch` | local | Remapped output does not match contract expectations (e.g. missing markdown, wrong image paths) |
| `pending_stub` | local | Markdown is exactly the 77-byte placeholder `MinerU processing pending - file not yet parsed.` -- NEVER a successful parse |
| `quality_failed` | local | Output exists but failed quality gate (e.g. repetition, garbled, under minimum byte threshold) |
| `missing_heading_contentful` | local | Output has substantial content (>= minimum byte threshold) but no `#` heading -- a review/normalization bucket, NOT the same as empty output or `pending_stub` |

### State Machine Transitions

```
prepared -> submitted -> uploaded -> waiting-file -> pending -> running -> [converting] -> done -> downloaded -> mapped
                                          |              |         |            |            |
                                          v              v         v            v            v
                                    pending_timeout  pending_timeout  pending_timeout  pending_timeout  failed
                                          |              |         |            |            |
                                          v              v         v            v            v
                                       next_action   next_action  next_action   next_action   error logged

done -> downloaded (success path)
        |
        v
     mapped
        |
        v
     [quality_failed] -> needs review/remediation
     [output_contract_mismatch] -> needs investigation
     [pending_stub] -> NEVER success; resubmit or investigate
     [missing_heading_contentful] -> normalization bucket; review but don't reject
```

### Transition Rules

- `prepared` -> `submitted`: Lifecycle runner calls `POST /api/v4/extract/task/batch` (URL-based) or `POST /api/v4/file-urls/batch` (local file upload).
- `submitted` -> `uploaded`: For local file upload path, runner PUTs file to each pre-signed URL. Server auto-detects upload and transitions to `waiting-file`.
- `waiting-file` / `pending` / `running` / `converting`: Polled via `GET /api/v4/extract-results/batch/{batch_id}`.
- `done`: `full_zip_url` field is present. Runner downloads the ZIP.
- `failed`: `err_msg` field explains why. Runner records error, does NOT retry automatically unless retryable error code.
- `pending_timeout`: Item exceeded configurable timeout (default: 30 min). Runner emits `next_action` guidance; this is resumable, NOT terminal failure.
- `stale_pending`: Item has been `pending` or `running` across N consecutive polls with no page progress. Runner emits `stale_pending` marker. Not terminal.
- `downloaded` -> `mapped`: Runner extracts ZIP, renames `{stem}.md` -> `<source_id>.md`, renames `{stem}.images/` -> `<source_id>.images/`, rewrites `![...](images/...)` to `![...](<source_id>.images/...)` inside the markdown.
- `mapped` -> quality evaluation: Runner checks for `pending_stub`, `missing_heading_contentful`, `quality_failed`, `output_contract_mismatch`.

### Official API Endpoints Used

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/v4/file-urls/batch` | POST | Get pre-signed upload URLs for local files (max 50 per request) |
| `/api/v4/extract/task/batch` | POST | Submit URL-based batch (max 50 per request) |
| `/api/v4/extract-results/batch/{batch_id}` | GET | Poll batch results; returns per-file state and `full_zip_url` when done |

All endpoints require `Authorization: Bearer {MINERU_TOKEN}` header. Non-HTML files use `model_version: "vlm"`. HTML/HTM files use `model_version: "MinerU-HTML"`.

Detailed request/response schemas are delegated to `convert-with-mineru/references/configuration.md` and the official API documentation at `C:\Users\zengw\mineru-downloads\MinerU 文档解析接口文档_1.md`.

### API Limits

| Limit | Value |
|---|---|
| Max file size | 200 MB |
| Max pages per file | 200 |
| Max files per batch request | 50 |
| Max high-priority pages per day | 1000 |
| Upload URL validity | 24 hours |

### Key Error Codes

| Code | Meaning | Retryable |
|---|---|---|
| `A0202` | Token error | No (fix token) |
| `-60005` | File > 200MB | No |
| `-60006` | File > 200 pages | No |
| `-60009` | Queue full | Yes (backoff) |
| `-60018` | Daily quota exhausted | No (wait until next day) |

## Token Redaction Rules

Tokens MUST NEVER appear in any logged, stored, or transmitted artifact outside of the live HTTP request.

- **Never log** `MINERU_TOKEN` values. Log messages and error traces must redact the token value (replace with `***`).
- **Never store** `Authorization` headers. Manifests, state files, batch JSON, CSVs must not contain Bearer tokens.
- **Never write** tokens to manifest/state/error messages. `mineru-batch.json`, `parse-manifest.csv`, `failures.csv`, `apply-manifest.jsonl` must never include token values.
- **Environment variable only**: The lifecycle runner reads `MINERU_TOKEN` from the environment at runtime and passes it directly in HTTP headers. No intermediary file stores it.

### Token Variable Separation

| Variable | Used By | Context |
|---|---|---|
| `MINERU_TOKEN` | Lifecycle runner, `convert-with-mineru` CLI | Precision API `/api/v4/*` authentication |
| `MINERU_API_TOKEN` | Official MCP Server (`mineru-open-mcp`) | Agent dialogue tool authentication |

These variables use different authentication systems and CANNOT be interchanged. Do not configure `MINERU_API_TOKEN` for the lifecycle runner. Do not configure `MINERU_TOKEN` for the MCP server.

## TTL and Stale Behavior

### Download URL Expiry

`full_zip_url` values returned by the Precision API have a finite lifetime (typically hours, not days). The lifecycle runner must:

- Download the ZIP immediately when `state=done` is observed.
- If a `done` item's ZIP download fails (HTTP 403/404), the URL may have expired. Mark as `stale_pending` with `next_action: "resubmit"`.
- Do not store `full_zip_url` in long-lived state expecting it to remain valid.

### Stale Pending Items

Items in `pending` or `running` state across multiple poll intervals with zero page progress are flagged as `stale_pending`. The lifecycle runner emits a `next_action` hint (e.g. "wait longer", "resubmit with lower batch size", "check token quota") but does not mark as `failed`.

### `pending_timeout` is Resumable

`pending_timeout` means the configured poll timeout was exceeded. It is NOT a terminal failure. The item can be resubmitted in a later batch or polled again with a longer timeout. The lifecycle runner distinguishes `pending_timeout` (resumable) from `failed` (terminal error from the API).

## Output Remapping Ownership

The lifecycle runner is solely responsible for output remapping. No other component (PowerShell scripts, raw ingest, validate-run) performs this renaming.

### Rules

1. **Markdown**: ZIP contains `{stem}.md` (where `{stem}` is the original filename without extension). Runner renames to `<source_id>.md`.
2. **Images**: ZIP contains `images/` directory. Runner renames to `<source_id>.images/`.
3. **Image hrefs**: Runner rewrites all `![...](images/...)` references inside the markdown to `![...](<source_id>.images/...)`.
4. **No JSON output**: Official output does not include `{stem}.json`, `content_list.json`, `layout.json`, `model.json`. These may exist inside the raw ZIP but are discarded after extraction (unless `--audit-dir` is enabled, in which case they go to the audit archive only).

### Contract Output

Each successfully processed item produces:

```text
run/mineru-output/<source_id>/<source_id>.md
run/mineru-output/<source_id>/<source_id>.images/  (if images present)
```

If no images were extracted, `<source_id>.images/` may not exist, but the markdown must not reference it.

## Local Recovery Rules

If downloaded artifacts already exist locally for a given `source_id`, the lifecycle runner must NOT resubmit the same file to MinerU. This avoids wasting API quota.

- Check `run/mineru-output/<source_id>/<source_id>.md` existence before submitting.
- If present and valid (non-stub, has content), skip submission and mark as `local_recovered`.
- If present but is a `pending_stub` (77 bytes), resubmit.
- Local recovery applies per-item, not per-batch. Items missing from local output are submitted normally.

## `pending_stub` vs `missing_heading_contentful`

These are EXPLICITLY DIFFERENT and must never be conflated.

### `pending_stub`

- Exactly 77 bytes: `MinerU processing pending - file not yet parsed.`
- This is a placeholder the MinerU API sometimes returns when a file hasn't been fully processed.
- It is NEVER a successful parse. Treat as if `state != done`.
- Action: resubmit or extend poll timeout. Do not pass to raw ingest.

### `missing_heading_contentful`

- Output has substantial content (>= configurable minimum byte threshold, default: 500 bytes) but no `#` heading.
- This is a review/normalization bucket. The content may be valid but missing structure (e.g. scanned image descriptions, tables without headings).
- It is NOT empty output and NOT a `pending_stub`.
- Action: flag for review, route to a normalization queue, but do NOT reject as failed.

## Committed-Only Batch Rules

- `mineru-batch.json` items array may only contain files whose `apply-manifest.jsonl` state is `committed` or `skipped_existing_committed`.
- States `planned`, `copied_temp`, `failed`, etc. must never enter the batch.
- Each item's `archive_path` and `archive_sha256` must match `apply-manifest.jsonl`.
- Each item's `source_id` comes from `mineru-batch.json` as generated by `prepare-mineru-batch.ps1`. The lifecycle runner must not re-derive source_id from filename or path.

## Lifecycle Runner Steps

The lifecycle runner processes `mineru-batch.json` through these phases:

1. **Read** `mineru-batch.json` from the run directory.
2. **Local recovery check**: For each item, check if `<source_id>.md` already exists locally. If valid, skip to `mapped`.
3. **Prepare**: Group items by `model_version` (vlm vs MinerU-HTML). Split into batches of <= 50.
4. **Submit**: `POST /api/v4/file-urls/batch` to get upload URLs. Each item transitions to `submitted`.
5. **Upload**: PUT each archive file to its pre-signed URL. Each item transitions to `uploaded`.
6. **Poll**: `GET /api/v4/extract-results/batch/{batch_id}` at configurable intervals (default: 30s). Track per-item state.
7. **Timeout/stale detection**: Flag items exceeding thresholds.
8. **Download**: For `done` items, download `full_zip_url`, extract.
9. **Remap**: Rename outputs, rewrite image paths. Transition to `mapped`.
10. **Validate**: Check for `pending_stub`, `missing_heading_contentful`, quality gates, contract compliance.
11. **Write artifacts**: Produce `parse-manifest.csv` and `failures.csv`.

### Processor Routing

The lifecycle runner reads `items[].processor` from `mineru-batch.json`:

| processor | api_family | model_version | Behavior |
|---|---|---|---|
| `convert_with_mineru` | `mineru_precision_api` | `vlm` | Precision API batch for non-HTML files |
| `convert_with_mineru_html` | `mineru_precision_api` | `MinerU-HTML` | Precision API batch for HTML/HTM files |
| `multimodal_looker` | null | null | Guidance-only, no API call |
| `mock` | null | null | Fixture testing only |
| `skip_unsupported` | null | null | Marked skipped with reason |

### Forbidden Processors

Every item in `mineru-batch.json` carries a `forbidden_processors` array. The lifecycle runner and any agent bridge MUST honor these:

- `mineru_parse_documents` -- MCP tool, never as batch path
- `/api/v1/agent/parse/*` -- Agent lightweight API, never as batch path
- `flash` -- Lightweight/flash path, never as default or fallback
- `pipeline_default` -- Relying on API's default `model_version=pipeline`, never
- `direct_http_precision_api` -- Calling Precision API directly without the lifecycle runner, never

## Capability Matrix

Each extension must declare: `extension`, `supported_for_archive`, `supported_for_mineru`, `mineru_mode`, `model_version`, `reason_if_unsupported`.

| extension | supported_for_archive | supported_for_mineru | mineru_mode | model_version | reason_if_unsupported |
| --- | --- | --- | --- | --- | --- |
| `.pdf` | true | true | `convert_with_mineru` | `vlm` | |
| `.doc` | true | true | `convert_with_mineru` | `vlm` | |
| `.docx` | true | true | `convert_with_mineru` | `vlm` | |
| `.ppt` | true | true | `convert_with_mineru` | `vlm` | |
| `.pptx` | true | true | `convert_with_mineru` | `vlm` | |
| `.xls` | true | true | `convert_with_mineru` | `vlm` | |
| `.xlsx` | true | true | `convert_with_mineru` | `vlm` | |
| `.png` | true | true | `convert_with_mineru` | `vlm` | |
| `.jpg` | true | true | `convert_with_mineru` | `vlm` | |
| `.jpeg` | true | true | `convert_with_mineru` | `vlm` | |
| `.jp2` | true | true | `convert_with_mineru` | `vlm` | |
| `.webp` | true | true | `convert_with_mineru` | `vlm` | |
| `.gif` | true | true | `convert_with_mineru` | `vlm` | |
| `.bmp` | true | true | `convert_with_mineru` | `vlm` | |
| `.html` | true | true | `convert_with_mineru_html` | `MinerU-HTML` | If config rejects HTML, mark `skip_unsupported` |
| `.htm` | true | true | `convert_with_mineru_html` | `MinerU-HTML` | If config rejects HTML, mark `skip_unsupported` |

Extensions not in the matrix default to `supported_for_archive=false`, `supported_for_mineru=false` unless explicitly allowlisted in config and documented in references.

### mineru_mode Meanings

| mode | Meaning |
| --- | --- |
| `convert_with_mineru` | Non-HTML documents via Precision API lifecycle runner, `model_version=vlm` |
| `convert_with_mineru_html` | HTML/HTM documents via Precision API lifecycle runner, `model_version=MinerU-HTML` |
| `multimodal_looker` | Explicit opt-in multimodal recognition guidance, no MinerU API call |
| `mock` | Fixture testing only, no real API calls |
| `skip_unsupported` | Marked skipped, reason recorded |

## MinerU Output Path

```
run/mineru-output/<source_id>/<source_id>.md
run/mineru-output/<source_id>/<source_id>.images/  (when images present)
```

`<source_id>` comes from the `source_id` field in `mineru-batch.json`. The lifecycle runner handles all renaming and image path rewriting. No other component owns this transformation.

## Mock Mode

Mock mode is for fixture testing only. No real MinerU API calls, no MCP:

- Normal markdown (written to `<source_id>.md`) goes to raw.
- Bad markdown (no heading, < 500 bytes, contains error placeholder) goes to failures.
- Raw collision uses suffix.
- `source_id` mismatch goes to failures.

Mock mode is triggered by `mineru-batch.json` item having `processor: "mock"` (or `mineru_route: "mock"` for backward compatibility). Mock markdown is written to `run/mineru-output/<source_id>/<source_id>.md`.
