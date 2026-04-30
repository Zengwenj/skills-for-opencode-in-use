# Validation Checklist

在声明“分析完成”或“仿写指南完成”前，逐项确认下面的检查。

## Input Checks

- 是否确认样本来自同一作者，或已明确写出无法确认
- 是否说明有效样本数量
- 是否标出过短样本、无效样本或 OCR 质量风险
- 是否说明主题覆盖是否足够支撑稳定 / 适应分析

## Analysis Checks

- 是否同时覆盖宏观层与微观层
- 是否按阈值区分了 `stable feature`、`adaptive feature`、`unconfirmed finding`
- 是否把主题变化与作者恒定风格区分开
- 是否避免把单篇偶发表达误判为长期特征

## Evidence Checks

- 每个关键结论是否附了原文依据
- 是否给出了 `sourceIndexes`
- 是否给出了 `frequency`
- 是否给出了 `confidenceLevel`

## Imitation Checks

- 是否优先保留思维模式与结构骨架，而不是只模仿词句表皮
- 是否明确区分 `mustKeep`、`canAdjust`、`mustNotCopy`
- 是否给出了“按作者习惯展开内容”的具体步骤，而不是空泛口号

## Output Checks

- JSON 键名是否统一
- 如果用户要求结构化输出，是否保留 warnings / unconfirmedFindings
- 如果样本存在明显冲突，是否避免输出“统一作者风格总定义”或“任何主题都通用”的单一路径
- 如果用户要求简化 JSON，是否仍保留关键结论对应的 evidence / frequency / confidence 边界
- 如果输出的是模板或示意结构，是否明确标注为模板而非正式归档结果
- 如果用户要求 office-doc 风格资产，是否说明“可适配”而非“已集成”
- 如果证据不足，是否明确降级，而不是用更强措辞掩盖不确定性

## Release Rule

只要上面任一关键项不满足，就不要把结果表述为“已经锁定作者稳定风格”。应改写为：

- 单篇风格观察
- 暂定稳定特征
- 低可信度比较结论
- 待补样本后再确认
