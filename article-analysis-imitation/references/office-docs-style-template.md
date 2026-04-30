# Office Docs Style Template

当用户希望把分析结果沉淀成可复用文体模板，或明确提到要给 `office-docs-writer` 使用时，按下面的结构生成一份 style profile。

这不是直接集成代码，也不是固定导入协议，而是一个**可映射的结构化风格资产**。

## Recommended Shape

```yaml
style_id: article-analysis-imitation/<custom-style-name>
style_label: 简短风格名
recommended_asset_type: guideline_like | template_like
source_basis:
  author: 作者名或匿名描述
  sample_count: 3
  confidence: high | medium | low
  sample_scope: 样本覆盖范围
  evidence_summary:
    stable_features_supported_by: [1, 2, 3]
    adaptive_features_supported_by: [2]
    warnings:
      - 样本主题覆盖不足时在此说明
applicable_scenarios:
  - 适用场景1
  - 适用场景2
document_types:
  - 工作总结
  - 汇报材料
  - 评论文章
core_intent:
  primary_goal: 主要表达目的
  audience_relation: 与读者的关系模式
macro_rules:
  thinking_pattern:
    - 核心思维路径1
    - 核心思维路径2
  value_orientation:
    - 稳定立场1
    - 稳定立场2
  structure_pattern:
    opener: 常见开头方式
    development: 常见推进方式
    closing: 常见收束方式
micro_rules:
  sentence_profile:
    preferred_length: short | mixed | long
    cadence: 节奏说明
  vocabulary_preferences:
    prefer:
      - 偏好词汇类型1
      - 偏好词汇类型2
    avoid:
      - 应避免的偏离性表达1
  rhetoric_markers:
    - 常见修辞或标记1
    - 常见修辞或标记2
  paragraph_habits:
    - 常见段落组织习惯1
    - 常见段落组织习惯2
adaptive_rules:
  by_topic:
    - topic: 主题类型
      keep:
        - 必须保留的内核
      adjust:
        - 可调整的部分
      avoid:
        - 此主题下要避免的误用
imitation_boundaries:
  must_keep:
    - 思维模式
    - 结构骨架
  can_adjust:
    - 论据素材
    - 主题措辞
  must_not_copy:
    - 一次性语句
    - 主题绑定表达
quality_checks:
  - 是否保留作者的切题方式
  - 是否保留作者的结构推进节奏
  - 是否只模仿表层而忽略思维方式
downstream_mapping_notes:
  office_docs_module:
    likely_targets:
      - guidelines/
      - templates/
    note: 这是可适配资产，不等于已完成模块内实际接线
```

## Usage Rules

1. `recommended_asset_type` 用来说明这份风格资产更像 guideline 还是 template。
2. `source_basis` 必须保留样本数量与可信度，避免把弱证据写成强模板。
3. `source_basis.evidence_summary` 用来保留模板背后的样本支撑边界，避免 downstream 把低证据模板当成稳定资产。
4. `macro_rules` 和 `micro_rules` 都要有，不能只写语言表层。
5. `adaptive_rules` 必须出现，否则 downstream 使用时容易把风格写死。
6. `must_not_copy` 必须写清，避免复用时变成低质量仿写。


## When To Prefer This Template

在以下情况优先输出这份模板：

- 用户说“沉淀成模板”
- 用户说“以后重复使用这套风格”
- 用户说“给 office-docs-writer 当一个可选风格”
- 用户不只想要一次分析，而是想要后续写作资产
