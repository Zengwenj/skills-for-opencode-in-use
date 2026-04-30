# Configuration

## 推荐方式

优先使用环境变量，尤其是 `MINERU_TOKEN`。

## 环境变量写法

### PowerShell 当前会话

```powershell
$env:MINERU_TOKEN = "<在这里填写你的 MineU Token>"
$env:DEFAULT_OUTPUT_ROOT = "C:\docs\_mineru"
```

### PowerShell 持久写入当前用户

```powershell
[System.Environment]::SetEnvironmentVariable(
  "MINERU_TOKEN",
  "<在这里填写你的 MineU Token>",
  "User"
)
```

### CMD 当前会话

```cmd
set MINERU_TOKEN=<在这里填写你的 MineU Token>
```

## 外置配置文件

真实配置文件不要放进技能目录。

建议位置：
- `C:\Users\zengw\.config\opencode\local\mineru.env`
- `C:\Users\zengw\.config\opencode\local\mineru.json`

如果技能目录里为了本地验证暂时保留了 `mineru..env` 一类文件，也要把它视为隔离对象：
- 不把它写进 `SKILL.md` 示例
- 不把它当成推荐配置路径
- 不把它带进分发或打包产物

## `.env` 写法

```dotenv
MINERU_TOKEN=<在这里填写你的 MineU Token>
DEFAULT_OUTPUT_ROOT=
```

规则：
- UTF-8
- `键=值`
- 支持 `#` 注释
- 不写 `Bearer ` 前缀

## `.json` 写法

```json
{
  "MINERU_TOKEN": "<在这里填写你的 MineU Token>",
  "DEFAULT_OUTPUT_ROOT": ""
}
```

## 优先级

1. 命令行显式参数
2. 环境变量（`MINERU_TOKEN`、`DEFAULT_OUTPUT_ROOT`）
3. `--config` 指定的 `.env` 或 `.json`

说明：
- `--output-root` 未显式传入时，才会回退到 `DEFAULT_OUTPUT_ROOT`

## 禁止项

- 不把真实 token 写进 `SKILL.md`
- 不把真实 token 写进 `examples/mineru.env` 或 `examples/mineru.json`
- 不把真实配置文件放进 `SelfMadeSkills\\convert-with-mineru\\`
