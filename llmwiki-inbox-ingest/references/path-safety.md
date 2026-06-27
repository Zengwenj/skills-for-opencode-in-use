# PowerShell、编码与路径安全契约

## PowerShell 版本

所有 `.ps1` 文件首行必须精确包含：

```powershell
#Requires -Version 7.0
```

## 编码规则

- 输出 UTF-8 no BOM。
- 中文路径、空格路径、特殊字符路径使用 `-LiteralPath`。
- 如需文本搜索，`Select-String` 必须使用 `-Encoding UTF8`。
- 中文路径业务判断避免不必要的 `-match`；年份提取等非语言正则允许使用明确正则。
- 使用 `[System.IO.Path]::GetFullPath()` 做路径归一。
- artifact 中路径分隔符归一为 `/`。

## Move-Item 区分

- **禁止**把源文件 Move-Item 到归档目录。
- **允许** archiveRoot 内同目录 temp → final 的原子 rename/Move-Item 提交。

## Safe Filename 生成规则

文件名安全处理步骤：

1. Unicode NFC 归一（`[string]::Normalize("FormC")`）。
2. 非法字符过滤/拒绝：`\ / : * ? " < > |`。若含任何非法字符，拒绝该文件名。
3. Windows reserved names 检测：`CON`、`PRN`、`AUX`、`NUL`、`COM1`-`COM9`、`LPT1`-`LPT9`。大小写不敏感。带任意扩展名（如 `CON.txt`）也要识别并拒绝。
4. trailing dot/space 处理：拒绝以 `.` 或空格结尾的文件名。
5. extension policy：extension 必须在 capability matrix 允许列表中，或 config 明确 allowlist。

## Unicode NFC 归一

所有路径在比较和写入前必须做 Unicode NFC 归一。不得接受 NFD 或其他归一形式的路径。

## Collision Suffix

当目标路径已存在且非精确 idempotent match 时，使用 collision suffix：

- 第一个冲突追加 `__2`
- 第二个冲突追加 `__3`
- 依此类推

## Canonical Root Containment

- 使用 `[System.IO.Path]::GetFullPath()` 归一后，验证目标路径以对应 root 路径开头。
- 防止 sibling-prefix attack：root 为 `C:\root` 时 `C:\root2\x.pdf` 不属于 root。
- raw 与 archive target 均不得 escape 对应 root。

## 路径分隔符归一

- artifact 中路径分隔符归一为 `/`。
- 内部计算使用平台原生分隔符。
