# Workflow Routing

An ordinary download request means find, download, and ingest. Only an explicit local-only request suppresses Zotero.

An ordinary translation request means translate and attach both translated-only and bilingual files. Only an explicit local-only request suppresses attachment.

Translation uses `qwenmt` with `qwen-mt-flash`, direct DashScope access, `1` QPS, and one worker by default. The orchestrator passes `bing` as the single best-effort fallback after restoring the original proxy environment. Use `-QwenNetwork system` when direct DashScope access is unavailable, `-TranslationService bing` only when the user explicitly requests Bing, and `-TranslationFallback none` when the user forbids fallback. Never add another provider implicitly.

If Qwen or Bing translation fails, keep the verified original and any completed Zotero ingest. Do not attach partial translation output. A later retry may reuse the original PDF and item without repeating discovery, download, or item creation.

Stop a paper after ambiguous identity, unavailable PDF, invalid PDF, denied authorization, or an unknown mutation outcome. Continue other papers in a batch. Resume only from verified stage artifacts; do not replay an uncertain Zotero mutation automatically.

For command-line batch runs on Windows PowerShell 5.1, pass a JSON array or one-paper-per-line text file with `-InputListPath`. Use `-Input` for one paper or for arrays supplied from an in-process PowerShell call.

Prefer PowerShell 7. The orchestrator resolves the current modern host or `pwsh.exe`; `-PowerShellPath` can specify a tested runtime. It does not assume that Windows PowerShell lacks `Get-FileHash`. A missing command is an environment/preflight problem, not evidence of a provider failure. `pdfinfo.exe` is required for completion verification; use the already configured bundled tool rather than installing another translation stack.

## Existing files and items

Use `-Mode translate -InputPdf <absolute PDF> -ItemKey <existing parent key>`. `-ItemKey` alone can select a readable original PDF from that parent. `-InputPdf -LocalOnly` translates locally without creating a Zotero item. Existing-file arguments are one-paper operations; use separate calls/manifests for distinct parent targets.

`-Mode ingest` needs a successful paper-record and verified download-result, supplied with `-PaperRecordPath` and `-DownloadResultPath`, or retained from the original run. It is not a metadata-free PDF import endpoint. Resolve uncertain identity through paper-find; do not create incomplete parents to work around missing metadata.

The internal `paper_id` is a UUID; it is not the Zotero item key. Existing item keys bind the target and do not replace the stage-result UUID. Reusing a run with a different source hash or parent/server is rejected.

## Resume and attachment repair

Pass the original `-RunId`, original paper inputs, and `-Resume`. Retain the requested workflow/local-only scope. Successful cached stages must still have unchanged readable files. Completed stored Chinese and bilingual attachments can be reused when bound to the same original.

A fresh run may adopt an existing stored translation pair. During resume, the original run's expected role/hash pairs and provider provenance remain authoritative: do not substitute another readable pair from the parent. Missing or changed retained outputs require reconciliation, not an implicit new translation. Rebinding an existing parent is not proof that an earlier unknown ingest succeeded.

For known attachment failure, `-ResumeState attachment-failed` schedules only attachment and verification. It requires the original run manifest, parent binding, and both valid output files. A missing or modified output blocks this repair path; it does not authorize retranslation.

Before any retry, read the parent's actual attachments. Existing valid role/hash matches are reused. An unreadable translated attachment record, unknown mutation result, server mismatch or unavailable API requires reconciliation rather than blindly creating another attachment. Do not silently reopen denied authorization. Individual stage result files are retained; new invocations cannot mistake stale success files for fresh results.

`-Mode verify -RunId <original run>` performs no translation or Zotero writes. It checks fresh files/attachments and can reconcile a previously uncertain write when the requested outputs actually exist. A schema-valid record or `verified: true` stored flag alone is insufficient.

## Failure diagnosis

For scan detection, distinguish an existing OCR text layer from a true image-only PDF. `-AutoEnableOcrWorkaround` uses the pinned engine's compatibility option; it does not perform OCR itself. Image-only documents require a verified lawful text version or an explicitly disclosed local OCR preprocessing step. Preserve the untouched source and record the preprocessing provenance; do not bypass scan detection and claim a translated image-only document.

Retain the translation helper's complete redacted diagnostic log and error kind. Scanned PDFs, invalid outputs and path errors should not trigger a provider fallback. Network, quota and authorization failures should be reported accurately and handled within the user's chosen provider policy. Do not retry billable translation to repair an upload or a final JSON-read error.

Completion requires fresh read-back for every output role requested. Report unique parent-paper totals, originals present, Chinese-only and bilingual coverage, generated/reused outputs, attachment failures and verification failures separately. A terminal batch state means the process ended, not that every paper succeeded. Never infer that translation is still running from an old progress status; check process liveness and recent progress.

When direct retrieval returns `needs_browser`, use an authorized Edge session to save the PDF into the run directory, verify its identity, and resume download validation. Do not use Zotero Connector to create an item during retrieval.
