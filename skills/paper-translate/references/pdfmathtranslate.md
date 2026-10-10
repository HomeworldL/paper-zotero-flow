# PDFMathTranslate-next Runtime

The pin is in `pdf2zh-release.json`: PDFMathTranslate-next `v2.9.0`, BabelDOC `v0.6.4`, official `with-assets-win64` archive, SHA-256 verified before extraction or execution.

The installer stores the runtime under `%LOCALAPPDATA%\PaperZoteroFlow\tools\pdf2zh-next\v2.9.0`. It reuses only an installation whose executable hash still matches its install record.

The installer accepts the executable names used by upstream documentation and release builds: `pdf2zh_next.exe` and `pdf2zh.exe`.

The translator uses English input, Simplified Chinese output, and Qwen-MT Flash by default. It resolves `DASHSCOPE_API_KEY` from the process, current-user, then machine environment. Prefer the environment variable over the `-QwenApiKey` parameter so the secret is not exposed in shell history. The PDFMathTranslate subprocess receives `--disable-config-auto-save`; results and logs must redact the key.

Qwen defaults to `-QwenNetwork direct`, `-QwenQps 1`, and `-QwenWorkers 1`. Direct mode adds only the DashScope hostname to the child process's `NO_PROXY` value and restores the previous value immediately afterward. It never edits WinINET, WinHTTP, or the user's persistent environment. Use `-QwenNetwork system` to retain the Windows system proxy. Bing always inherits the original proxy environment. All translator subprocesses use a hidden window.

The default execution policy is `-Service qwenmt -FallbackService bing`:

1. Run Qwen-MT with model `qwen-mt-flash`.
2. If the key is missing or Qwen fails, retain the reason and make one short-text Bing availability probe.
3. Run Bing once only when the probe succeeds. Bing is deprecated upstream, so treat it as best-effort rather than a guaranteed engine.
4. If Bing also fails, stop translation and report both causes. Do not silently choose a third service.

An explicit `-Service bing` skips Qwen and uses Bing directly. `-FallbackService none` disables automatic fallback. Extracted text leaves the machine for both services: Qwen sends it to Alibaba Cloud and Bing sends it to Microsoft.

Each provider attempt uses an isolated working directory so partial Qwen output cannot be mistaken for Bing output. Success requires exactly one mono PDF and one dual PDF from the successful attempt. Accept both legacy `-mono.pdf` / `-dual.pdf` names and the v2.9 `.zh.mono.pdf` / `.zh.dual.pdf` names. Each output must have a valid PDF signature, nontrivial size, and SHA-256. The version-1 result also records `service_used`, `fallback_used`, `fallback_reason`, `qwen_network`, `qwen_qps`, `qwen_workers`, and `attempts[].duration_seconds`.

The working directory is a fresh, short `pzt-<uuid>` child of the process temp directory; a staged `source.pdf` avoids long original filenames. Publishing keeps a short original stem or a safe paper ID and refuses to overwrite existing outputs. Confirm and reuse existing role/hash matches before another translation attempt. Temp cleanup is limited to the resolved attempt directory and does not remove published PDFs or diagnostics.

`outputs.diagnostic_logs` records complete redacted log paths. Failed attempts retain their root cause even when it lies outside `log_tail`. `errors[].kind` distinguishes scanned PDFs, invalid outputs, path errors, authorization, quota/rate limits and other provider/runtime failures. No scanned-PDF, path-length or invalid-output failure automatically invokes Bing, because changing providers does not solve those document/publishing faults. The default configurable provider fallback remains best-effort for other errors; honor an explicit Qwen-only request with `none`.

Do not infer zero billable usage from a translator log that reports `Total Token Usage: 0`; a provider may not populate that counter. Report measured API usage only when available, mark estimates explicitly, and use the provider's usage/billing records for actual charges. Reusing validated PDFs for attachment repair should invoke no translation provider.

`-AutoEnableOcrWorkaround` passes the pinned engine's native compatibility flag. This can render text from existing hidden OCR layers correctly; it is not an OCR recognizer. For truly image-only pages, find a verified text original or prepare an OCR text layer locally with suitable authorization. Keep page images and originals intact, record the preprocessing, and inspect output layout. Do not interpret absence of detectable English text or an unchanged image as translation success.

PDFMathTranslate-next is the supported entry point. BabelDOC remains its internal layout engine. Do not automatically invoke PDFMathTranslate 1.x or depend on `zotero-pdf2zh`; keep Zotero attachment handling in `$paper-zotero-ingest`.
