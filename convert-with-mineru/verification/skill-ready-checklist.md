# Skill Ready Checklist

- [x] `SKILL.md` 只有 `name` / `description` 两个 frontmatter 字段
- [x] `description` 只描述触发条件，不描述工作流
- [x] 轻量模式规则写清楚：单文件、Markdown-only
- [x] 精准模式规则写清楚：批量、目录、JSON 默认走这里
- [x] MineU 支持矩阵与 fallback 规则写清楚
- [x] 中文手写扫描件策略写清楚
- [x] 输出命名规则写清楚
- [x] 配置与示例文件不含真实 token
- [x] 已写清楚“技能 contract”与 MinerU 官方原生产物不是同一层概念
- [x] `mineru..env` 这类本地真实配置已按隔离对象处理，不进入示例、引用和分发链路
- [x] 单元测试通过
- [x] 过滤副本不包含 `.venv/`、`.pytest_cache/`、`live-repeat-output/`、`HANDOFF-2026-04-01.md`、`mineru..env`
- [x] 压力场景复核完成
