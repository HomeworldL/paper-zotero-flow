---
name: paper-translate
description: Translate a research PDF into Chinese-only and bilingual PDFs with the pinned PDFMathTranslate-next Windows executable, then attach them to Zotero by default. Use for layout-preserving paper translation.
---

# Paper Translate

Use the pinned PDFMathTranslate-next Windows executable. Do not install BabelDOC, Python, uv, conda, Docker, or a Zotero translation plugin for this workflow.

The default service is Qwen-MT Flash (`qwen-mt-flash`). Read `DASHSCOPE_API_KEY` from the process, user, or machine environment; never print it or write it to a result or manifest. Run Qwen at `1` QPS with one worker and bypass the Windows system proxy only for the DashScope host. Use `-QwenNetwork system` only when direct DashScope access is unavailable. Restore the prior proxy environment before any Bing fallback. Before the first translation in a run, disclose that extracted paper text is sent to Alibaba Cloud. If Qwen is unavailable or fails, the script may use Bing once as a best-effort fallback after a short live probe. Disclose that this sends extracted text to Microsoft and that upstream has deprecated Bing support.

Use `scripts/Install-Pdf2zh.ps1` to install or verify the pinned runtime, then `scripts/Invoke-PaperTranslation.ps1`. The script produces both Chinese-only and bilingual PDFs, validates them, and records the actual service, fallback reason, and per-attempt elapsed time. Read [references/pdfmathtranslate.md](references/pdfmathtranslate.md) for the pin, credential lookup, fallback rules, and output contract.

Use `-FallbackService none` when the user selected Qwen-only operation. Document/scan/path failures do not become provider-fallback requests. Diagnose a scan detection result before retrying: `-AutoEnableOcrWorkaround` can handle an existing OCR text layer, but does not recognize image-only text itself. Keep the untouched original and record any separate, disclosed OCR preprocessing.

The helper uses an isolated short working path, preserves published output files instead of overwriting them, and retains complete **redacted** diagnostic logs under the output directory's `.diagnostics`. Report the result's error kind and diagnostic path rather than only its truncated log tail. Do not display secrets or paper-body text from raw logs.

By default pass verified translated and bilingual artifacts to `$paper-zotero-ingest`. An explicit local-only request stops after translation. If attachment fails, retain both outputs and retry attachment without retranslating.

Local generation is not Zotero completion. After attachment, freshly verify both stored role/hash matches and PDF readability. A successfully launched subprocess, zero exit code without outputs, or successful attachment metadata alone is insufficient.

Launch PowerShell helpers and PDFMathTranslate in hidden windows. Never change the user's global Windows proxy settings.
