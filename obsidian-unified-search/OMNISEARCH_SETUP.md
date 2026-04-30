# Omnisearch 配置指南

## 安装步骤

由于 Omnisearch 是 Obsidian 插件，需要在 Obsidian 应用内手动安装：

### 步骤 1：打开 Obsidian

启动 Obsidian 应用并打开你的 vault：`D:\ObsBocdVault`

### 步骤 2：安装 Omnisearch 插件

1. 点击左下角的 **设置**（齿轮图标）
2. 选择 **第三方插件**（Community Plugins）
3. 关闭 **安全模式**（Safe Mode）- 点击 Turn off
4. 点击 **浏览**（Browse）
5. 搜索 **"Omnisearch"**
6. 点击 **安装**（Install）
7. 安装完成后点击 **启用**（Enable）

### 步骤 3：启用 HTTP Server

1. 在设置中找到 **Omnisearch**（已安装的插件列表中）
2. 点击打开 Omnisearch 设置
3. 找到 **"Enable local HTTP server"** 选项
4. 勾选启用
5. 确认端口为 **51361**（默认）
6. 关闭设置窗口

### 步骤 4：验证

在 PowerShell 或 Git Bash 中运行：

```bash
curl http://localhost:51361/search?q=欢迎
```

如果返回 JSON 格式的搜索结果，说明配置成功！

## 配置检查清单

- [ ] Obsidian 已打开 vault: D:\ObsBocdVault
- [ ] Omnisearch 插件已安装并启用
- [ ] HTTP server 已启用（端口 51361）
- [ ] 测试搜索成功

## 故障排除

### HTTP 连接被拒绝

如果 `curl` 命令失败：

1. 确认 Obsidian 正在运行
2. 确认 Omnisearch 插件已启用
3. 在 Omnisearch 设置中重新勾选 HTTP server
4. 检查防火墙是否阻止了端口 51361

### 搜索结果为空

首次安装后，Omnisearch 需要时间索引你的 vault：

1. 等待几分钟让索引完成
2. 在 Omnisearch 设置中查看索引状态
3. 可以尝试重新索引：在 Omnisearch 设置中找到 "Clear cache and re-index"

## 安装后的优势

启用 Omnisearch HTTP 后，你将获得：

1. **最快的搜索速度** - 比官方 CLI 和 obs CLI 都快
2. **更好的容错性** - 支持拼写错误，智能匹配
3. **OCR 支持** - 可以搜索图片中的文字（需配合 Text Extractor 插件）
4. **PDF 支持** - 可以搜索 PDF 文档内容

## 与三层搜索方案的集成

安装完成后，智能搜索脚本会自动优先使用 Omnisearch HTTP：

```
搜索优先级：
1. Omnisearch HTTP (最快) ✅
2. 官方 CLI (功能全)
3. obs CLI (独立运行)
4. ripgrep (兜底)
```
