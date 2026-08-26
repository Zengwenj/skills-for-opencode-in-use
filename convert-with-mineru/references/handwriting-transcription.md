# Handwriting Transcription

## 适用场景

- 中文手写扫描 PDF 或手写图片
- 手写内容存在难以辨认的部分，需要视觉角色对照页图补充识别
- 转写稿需要保守的语义修订以还原原始手写内容

## 自动化手写管道（canonical）

一条命令启动（MinerU 先转，不再前置绕过）：

```powershell
python -m scripts.mineru_convert <手写文件> --prefer-multimodal
```

三段式分工（脚本做确定性工作，agent 编排层做识别与修订）：

1. **脚本 prepare**：输入预检（DPI/宽高比 WARNING）→ MinerU Precision vlm 高精度转写 → 生成自包含任务包 `<stem>.handwriting-task/`（task.json + TASK.md + draft.md + pages/ 页图）并打印后续步骤 guidance。
2. **agent 编排层**：
   - 视觉补充识别（multimodal-looker subagent / omp vision role，模型基准 `gpt-5.6-terra:xhigh` 或 `kimi-k3:max`，**禁止 glm 系列**）按 TASK.md 对照页图校对草稿 → 写 `supplement.md`
   - 语义修订（主 agent 或任意强文本角色，不绑定模型）按分级修订原则 → 写 `revised.md`
3. **脚本 finalize**：

```powershell
python -m scripts.mineru_handwriting finalize <任务包目录>
```

校验产物与页标记齐全 → 重叠去重（后批为准）→ 剥离两级标记入报告 → 图片引用机械回填 → 终稿门控复跑 → `source.md` ← 终稿。

## 核心原则（已固化于 TASK.md 模板）

**忠实抄录（视觉阶段）**：
- 只修正草稿中与页图不符的转写；不补写、不润色、不猜测
- 看不清的字打 `<!-- low-confidence: 该处无法辨认 -->` 占位，禁止猜测填字
- 图片引用行 `![...](...)` 原样保留（缺失会被 finalize 机械补录到文末，破坏位置）
- 表格按 Markdown 逐格转写；公式用 `$...$` 保留
- 每页输出以 `<!-- page: N -->` 行开头

**分级修订（修订阶段）**：
1. 明确疑似识别错误导致的错字/串行/重复 → 修正
2. 明确是原文风格（口语化、语病、残句）→ 保留原样
3. 中间地带 → 打 `<!-- uncertain: 原文X，疑为Y -->` 留人工
4. 遇 low-confidence：上下文能定夺则修正，不能定夺保留原样并升级为 uncertain
5. 禁止增删段落、改结构、改图片引用、把人名/地名/数字"纠正"为常见词

**分批规则**：≤10 页单批全量；>10 页按 ≤5 页/批且每批重叠上一批最后一页，重叠页以后批为准（finalize 机械去重，不依赖模型自觉）。

## 降级

- 页图渲染失败（加密/损坏 PDF）→ 任务包标记 degraded，草稿版 source.md 已产出不受影响
- agent 环节未执行/不完整（supplement/revised 缺失、页标记不符）→ finalize 报错列出缺失项，source.md 保持草稿版，任务包可反复重试（自包含，不依赖会话记忆）
- 终稿门控失败 → exit 2 交人工裁决，不静默回退

## 验收

- 终稿门控全绿
- 人工抽查三稿 diff：draft.md / supplement.md / revised.md 的首、中、末页至少各看一处
- 报告（`handwriting-report.json`）中的 low-confidence / uncertain 清单逐条人工裁决

## 已知限制

- 多栏/竖排/批注穿插导致的阅读顺序错乱不在本管道处理范围
- 印刷+手写混排表单（印刷标签+手写填值）不在本管道处理范围

## 禁止项

- 不把多模态校对结果写成 MinerU 的 `原名.json`
- 视觉校对环节配置 glm 系列模型（用户环境契约：multimodal-looker subagent / omp vision role 专用）
- 看不清的内容猜测补写
- 语义修订阶段做"润色成文"式的改写（目标是还原原文，不是美化）
- 把手写管道当作默认路径（必须显式 `--prefer-multimodal` opt-in）
- 不在 low-confidence/uncertain 仍存在时宣称转写完成
