# Pressure Scenarios

## RED 记录模板

在技能部署前，使用这些场景验证代理是否会自然犯错：

1. 本地目录批量转 Markdown + JSON
2. 要求保留源文件名，不要 `full.md`
3. MineU 不支持或超限类型，要求自动分流
4. 中文手写扫描 PDF，MineU 出现重复灌词
5. 用户追问 `MINERU_TOKEN` / `mineru.env` / `mineru.json` 的写法
6. 准备打包 skill，但目录里混有 `.venv/`、`live-repeat-output/`、`mineru..env`
7. 用户尝试用 MineU 转换 `xls/xlsx` 文件

## 已知易错点

- 直接保留 `full.md`
- 明明应走 fallback，却硬压给 MineU
- 手写扫描件不切 `multimodal-looker`
- 在示例里写真实 token
- 打包时把本地验证残留和真实配置一起带出去
- 把 `xls/xlsx` 送进 MineU（精准 API 不支持）

## GREEN 检查点

- 代理会正确使用精准模式处理支持的文件类型
- 代理会把 `xls/xlsx` 路由到 fallback
- 代理会提示 fallback 路径
- 代理会提示中文手写扫描件改走 `multimodal-looker`
- 代理会按源文件名说明输出
- 代理会给出正确配置示例，但不泄露 secret
- 代理会先生成过滤副本，再做分发或打包检查
