# Style Analysis Schema

当用户需要结构化输出时，优先使用下面的框架。字段可以按任务略微增删，但不要丢掉 `stableFeatures`、`adaptiveFeatures`、`imitationGuide`、`warnings` 这四块核心内容。

## Required Contract

```json
{
  "authorStyleSummary": {
    "coreDefinition": "一句话概括作者最本质的写法",
    "stabilityAssessment": "稳定程度与依据",
    "adaptabilityAssessment": "作者如何随主题调整",
    "distinctiveness": "与同类写法相比的区别",
    "confidenceLevel": "high | medium | low",
    "evidenceQuotes": ["原文引句1", "原文引句2"],
    "sourceIndexes": [1, 2],
    "frequency": "2/3"
  },
  "stableFeatures": {
    "thinkingPattern": {
      "pattern": "作者稳定的思考路径",
      "imitationNotes": ["要点1", "要点2"],
      "confidenceLevel": "high | medium | low",
      "evidenceQuotes": ["原文引句"],
      "sourceIndexes": [1, 2, 3],
      "frequency": "3/3"
    },
    "expressionIntent": {
      "pattern": "解释/判断/说服/动员/记录等",
      "imitationNotes": ["要点1", "要点2"],
      "confidenceLevel": "high | medium | low",
      "evidenceQuotes": ["原文引句"],
      "sourceIndexes": [1, 2],
      "frequency": "2/3"
    },
    "structurePattern": {
      "pattern": "常见开头-展开-收束套路",
      "imitationNotes": ["要点1", "要点2"],
      "confidenceLevel": "high | medium | low",
      "evidenceQuotes": ["原文引句"],
      "sourceIndexes": [1, 2, 3],
      "frequency": "3/3"
    },
    "languagePattern": {
      "sentenceTraits": ["特征1", "特征2"],
      "vocabularyPreferences": ["偏好1", "偏好2"],
      "signatureMarkers": ["表达1", "表达2"],
      "formalityLevel": 3,
      "imitationNotes": ["要点1", "要点2"],
      "confidenceLevel": "high | medium | low",
      "evidenceQuotes": ["原文引句"],
      "sourceIndexes": [1, 2, 3],
      "frequency": "3/3"
    }
  },
  "adaptiveFeatures": [
    {
      "topicLabel": "评论类 / 汇报类 / 叙事类",
      "topicSignals": ["判断依据1", "判断依据2"],
      "thinkingAdjustment": "此主题下如何调整思路",
      "structureAdjustment": "此主题下如何调整结构",
      "languageAdjustment": "此主题下如何调整语气与措辞",
      "emotionalIntensity": 2,
      "confidenceLevel": "high | medium | low",
      "evidenceQuotes": ["原文引句"],
      "sourceIndexes": [2],
      "frequency": "1/3"
    }
  ],
  "perSampleAnalysis": [
    {
      "sampleIndex": 1,
      "sampleLabel": "文章标题或编号",
      "topicLabel": "主题标签",
      "macroStyle": {
        "thinkingPattern": "该篇中的思维框架",
        "valueOrientation": "该篇中的判断与立场",
        "expressionIntent": "该篇主要写作目的",
        "stylePositioning": "该篇风格归属"
      },
      "microStyle": {
        "languageTraits": "句式、词汇、修辞",
        "structureTraits": "段落与转承方式",
        "argumentTraits": "视角与组织方式",
        "emotionalRhythm": "语气、节奏、张力",
        "signatureMarkers": "独特表达或习惯",
        "thinkingDepth": 3
      },
      "notes": ["补充说明1", "补充说明2"]
    }
  ],
  "styleVariationAnalysis": {
    "topicInfluence": "哪些变化来自主题",
    "audienceOrScenarioInfluence": "哪些变化来自对象或场景",
    "stableCore": ["内核1", "内核2"],
    "doNotMisclassify": ["误判1", "误判2"]
  },
  "imitationGuide": {
    "priorityOrder": [
      "先模仿思维方式",
      "再模仿结构推进",
      "再模仿语言和标记"
    ],
    "mustKeep": ["思维模式", "结构骨架", "表达意图"],
    "canAdjust": ["论据素材", "主题措辞", "场景表达"],
    "mustNotCopy": ["一次性语句", "主题绑定表达", "偶发修辞"],
    "writingSteps": [
      "确定作者常用切题方式",
      "将新主题映射到作者常用论述路径",
      "搭建符合作者习惯的结构骨架",
      "按接近作者的密度和节奏填充内容",
      "补入标志性语言与修辞",
      "根据主题调整适应性特征",
      "最后校准整体气质"
    ],
    "commonMistakes": [
      "只学表层词句，不学思维路径",
      "忽略主题适应性",
      "照抄一次性表达",
      "模仿过度，写成夸张复制品"
    ]
  },
  "warnings": [
    "样本仅 2 篇，稳定特征仅为暂定结论"
  ],
  "unconfirmedFindings": [
    {
      "finding": "疑似高 formal tone",
      "reason": "仅出现在 1/3 样本中，且明显受主题影响"
    }
  ]
}
```

## Rules

1. 所有关键结论都必须包含 `confidenceLevel`、`evidenceQuotes`、`sourceIndexes`、`frequency`。
2. 如果没有足够证据，不要删除这些字段来“省事”，而应把结论放入 `warnings` 或 `unconfirmedFindings`。
3. `formalityLevel`、`emotionalIntensity`、`thinkingDepth` 的评分标准见 `@references/scoring-anchors.md`。
4. 如果用户不需要 JSON，可以把这一结构转换成自然语言小节，但保留同样的信息顺序与证据边界。
5. 如果样本之间存在明显冲突，不要产出单一 `coreDefinition` 作为“任何主题都通用”的统一写法，应在 `adaptiveFeatures`、`styleVariationAnalysis` 或 `unconfirmedFindings` 中显式保留分歧。
6. 如果用户要求“简化 JSON”，可以省略非关键辅助字段，但只要保留关键判断，就必须同时保留它们对应的 `confidenceLevel`、`evidenceQuotes`、`sourceIndexes`、`frequency`，并至少保留 `warnings`。
7. 不要输出仅含占位文本、却看起来像正式归档结果的 JSON；占位结构只能明确标记为模板或示意。
