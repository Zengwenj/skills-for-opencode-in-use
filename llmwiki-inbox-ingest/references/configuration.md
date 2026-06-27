# 配置发现、初始化与运行目录

## 核心原则

所有路径均来自 config 或 CLI 参数：`inboxRoot`、`archiveRoot`、`rawSourcesRoot`、`reviewRoot`、`themeList`、`scope`。脚本不得内置项目路径默认值。

## 配置发现规则

1. 默认从当前工作目录查找 `.llmwiki-ingest/config.json`。
2. 当前目录没有时，向父目录逐级查找第一个 `.llmwiki-ingest/config.json`。
3. CLI 参数覆盖 config 中对应字段。
4. 找不到 config 时：非零退出，输出错误信息。
5. 找不到 config 时不得 scan、不得 proposal、不得 apply、不得 prepare MinerU、不得 ingest raw。

## --init 规则

- 创建 `.llmwiki-ingest/config.json` 示例或将示例输出到用户指定路径。
- 创建注释化审批模板说明，但 YAML frontmatter 键必须保持精确。
- 初始化完成后立即退出，不继续 scan。
- 输出必须说明下一步要编辑哪些字段。

## 运行目录格式

```text
reviewRoot/YYYYMMDD-HHMMSS-<6位随机hex>/
```

规则：

- `<6位随机hex>` 必须为小写或大写十六进制字符，长度 6。
- run 目录已存在：fail closed，不得向其中写入。
- apply 阶段创建 `.apply.lock`。
- `.apply.lock` 已存在：拒绝执行。第一版默认无 stale-lock 自动解除。
- runtime evidence 放在 run 目录内的 `evidence/`。

## config.json 字段

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `inboxRoot` | string | 是 | inbox 源文件根目录 |
| `archiveRoot` | string | 是 | 归档目标根目录 |
| `rawSourcesRoot` | string | 是 | raw Markdown 输出根目录 |
| `reviewRoot` | string | 是 | 运行产物根目录 |
| `themeList` | array[string] | 是 | 唯一合法主题来源；主题名必须通过 Windows 文件夹名校验 |
| `scope` | string | 是 | 扫描范围，默认 `root_inbox_recursive` |

`themeList` 必填，且作为唯一合法主题来源。主题名必须通过 Windows 文件夹名校验（不得为保留名如 `CON`、不得含非法字符）。

## 错误信息标准

每条错误必须包含四项内容：

1. 发生了什么
2. 哪个文件/字段出错
3. 期望值是什么
4. 下一步怎么修

## 路径/文件夹不耦合

脚本逻辑不得把 `E:\llmwikivault`、`资料库`、`bocd-working-wiki` 作为默认值或逻辑常量。这些字符串只允许出现在文档示例、示例配置或测试 fixture allowlist 中。
