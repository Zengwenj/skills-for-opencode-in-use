# Scan 与 Taxonomy 规则

## Scan 排除规则

scan 只递归扫描 `inboxRoot` 下文件，必须排除以下内容：

| 排除项 | 说明 |
| --- | --- |
| `.index.md` | 索引文件，不是源文件 |
| `.obsidian/` | Obsidian 配置目录 |
| `.llmwiki-ingest/` | 本 skill 自身配置 |
| `reviewRoot` | 运行产物目录 |
| `rawSourcesRoot` | 已解析的 raw 原料 |
| 隐藏目录 | 以 `.` 开头的目录（除排除白名单外） |
| 运行目录 | 与当前或历史 run ID 格式匹配的目录 |

## 年份提取

年份提取必须使用正则：`(?<!\d)(20[0-2][0-9])(?!\d)`。

- `2026` 匹配 ✓
- `12026` 不匹配（前面有数字）
- `20266` 不匹配（后面有数字）
- 拒绝两位数年份或 1900 年代

## 主题推断

- `themeList` 是唯一合法主题来源。
- 从文件路径、父目录名推断主题时，必须与 `themeList` 精确匹配。
- 未知主题：`inferred_theme` 输出空字符串，`review_needed` 设为 `true`。

## Pack 规则

- inbox 内已有 `*-pack` 目录必须标记 `review_needed: true`。
- 不得自动合并到正式 archive pack。
- pack 内文件单独进入 inventory，但需关联 pack_key。

## Zip 策略

| 属性 | 值 |
| --- | --- |
| 进入 inventory | 是 |
| 默认 `enter_raw_sources` | `false` |
| 默认进入 MinerU | 否 |

## .txt / .md 策略

| 属性 | 值 |
| --- | --- |
| 作为文本来源 | 是 |
| 经 MinerU | 否 |
| 是否进入 raw | 由 policy 与审批决定 |

## Code / Cache / Temp 策略

- 进入 inventory 或 excluded 记录。
- 默认不入 raw。

## Unsupported Extension

- 进入 `failures.csv` 或 `review_needed`。
- 不得静默跳过。

## raw/sources 分类

- `raw/sources` 不另建第二套分类体系。
- raw 继承 committed archive 的 `theme` 和 `year`。
