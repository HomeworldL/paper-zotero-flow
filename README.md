# Paper Zotero Flow

An end-to-end workflow for finding, downloading, translating, and organizing research papers in Zotero.

面向 Windows 的论文处理技能套件：从已知论文的身份确认、合法 PDF 下载，到 Zotero 入库和中文翻译。既可使用完整流程，也可单独调用某一阶段。

## 技能

| 技能 | 职责 |
| --- | --- |
| [paper-zotero-flow](skills/paper-zotero-flow/SKILL.md) | 编排完整流程，维护阶段记录、断点续接与完成核验。 |
| [paper-find](skills/paper-find/SKILL.md) | 根据标题、DOI、arXiv 编号或链接确认论文身份与元数据。 |
| [paper-download](skills/paper-download/SKILL.md) | 获取合法原文 PDF 并验证文件。 |
| [paper-zotero-ingest](skills/paper-zotero-ingest/SKILL.md) | 创建或复用 Zotero 条目、归入分类并挂载 PDF。 |
| [paper-translate](skills/paper-translate/SKILL.md) | 生成纯中文和中英文对照 PDF。 |

## 使用准备

- 保持 `skills/` 下五个技能的目录名和相邻关系，将其复制到所用智能体的技能目录；替换已有同名技能前先备份。
- 推荐 PowerShell 7；完成核验需要可用的 `pdfinfo.exe`。
- 入库需要运行中的 Zotero 10 与 Local API，并在真正写入时取得 Zotero 授权。文件上传涉及多次写入，需要 **Always Allow**。
- 翻译使用固定版本的 PDFMathTranslate-next Windows 运行时。由 [安装脚本](skills/paper-translate/scripts/Install-Pdf2zh.ps1) 验证或安装，不在仓库中分发引擎二进制。
- 默认翻译服务是 Qwen-MT Flash，通过环境变量 `DASHSCOPE_API_KEY` 提供密钥。不要将密钥、私人配置或论文运行记录提交到仓库。

先阅读所选技能的 `SKILL.md`，再按其中的脚本和参考说明执行。总入口会根据任务调用其他技能，不要求每次都走完整流程。

## 使用示例

可以向支持这些技能的智能体提出：

> 使用 paper-zotero-flow 下载这篇论文，放到指定 Zotero 分类；使用 Qwen 翻译并挂载纯中文和双语 PDF，不使用其他翻译服务。

> 两份译文已经在本地，复用它们补挂到已有 Zotero 条目，不要重新翻译。

> 核查原批次是否完成，只检查文件和 Zotero 附件，不开始新任务。

## 运行边界

- 只获取合法可访问的论文，不绕过访问限制；论文身份不确定时停止该篇。
- 复用已验证的原文、译文和父条目；挂载失败不重新翻译。写入结果不明时先只读核查，不自动重复上传。
- “译文已生成”“附件已挂载”和“Zotero 核验通过”是不同状态。完成判定检查文件可读性、附件角色、分类与 SHA-256 匹配，不代表逐页人工审校。
- Qwen 翻译会将提取的正文发送到阿里云，并可能产生费用。仅用 Qwen 时，总入口指定 `-TranslationFallback none`；单独翻译指定 `-FallbackService none`。可选 Bing 回退会将正文发送到 Microsoft，仅按已获授权的服务策略使用。
- 扫描件需要区分已有 OCR 文本层与纯图像页面；兼容开关不是 OCR 识别器。

## 测试

各技能的 `tests/` 包含隔离测试与模拟数据。分别运行各技能的 `Run-Tests.ps1`；总入口另有 `Run-RegressionTests.ps1` 和 `Run-ReadbackTests.py`，翻译技能另有 `Run-DiagnosticTests.ps1`。

测试不需要真实论文或真实翻译密钥。部分测试需 PowerShell 7、`pdfinfo.exe`；只读核查测试使用 Python 标准库和临时回环接口，不访问真实 Zotero。隔离测试不能替代真实服务的端到端验收。

下载技能的旧测试会启动 Windows PowerShell 子进程。请直接使用以下方式运行该套测试，避免从 PowerShell 7 脚本上下文继承不兼容的模块搜索路径：

```powershell
powershell.exe -NoProfile -File .\skills\paper-download\tests\Run-Tests.ps1
```

其他 PowerShell 测试使用 `pwsh.exe -NoProfile -File <测试脚本路径>`；只读核查测试使用 `python -X utf8 .\skills\paper-zotero-flow\tests\Run-ReadbackTests.py`。

## 许可

本仓库采用 [MIT License](LICENSE)。外部服务、论文及翻译引擎适用各自的许可与使用条款。
