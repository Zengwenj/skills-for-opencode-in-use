# Handwriting Transcription

## 适用场景

- 中文手写扫描 PDF 或手写图片
- MinerU vlm OCR 输出出现明显重复灌词
- MinerU 输出与版面明显不符
- 低质扫描件 vlm 转换质量不足

## 推荐流程：vlm 优先

1. 所有 PDF 和图片默认走 MinerU Precision vlm 模型（`route_file()` 返回 `mineru`）。
2. 检查 vlm 输出质量：
   - 质量门控自动检测 `repetition_consecutive` / `repetition_global` / `garbled` 门控
   - 人工抽查首页、中间页、末页
3. 若 vlm 输出满足需求，流程结束。

## vlm 失败后：显式 opt-in multimodal_looker

若 vlm 输出在质量门控处失败，或人工检查发现明显灌词/错位：
- 重新传入 `--prefer-multimodal` flag，路由到 `multimodal_looker`（guidance-only）
- guidance 内容包含 source、gate、reason、suggested route
- `multimodal_looker` 不真实调用多模态工具，由调用方根据 guidance 自行决策

## 手动 multimodal 转写流程（本地环境）

若本机已安装 `multimodal-looker` 工具，可参照以下流程：

1. 确认输入类型：PDF 还是图像集合。
2. 确认范围：整份都手写，还是部分页手写。
3. 切分材料：
   - 图像按张处理。
   - PDF 按页或按 5-10 页页段处理。
4. 调用转写：
   - 忠实抄录，不补写，不润色，不猜测缺字
5. 重复/幻觉检查：
   - 若某一页段出现重复句段，缩小页段重试
6. 拼接输出：
   - 写 `原名.md`
   - 保留页码边界
7. 抽样复核：首页、中间页、末页至少各看一处

## 禁止项

- 不把多模态转写结果写成 MinerU 的 `原名.json`
- 不把多模态转写结果与 MinerU 输出混写
- 不在重复灌词仍明显存在时宣称识别完成
- 不把 `multimodal_looker` 当作默认路径（必须显式 `--prefer-multimodal` opt-in）
