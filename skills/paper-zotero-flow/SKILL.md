---
name: paper-zotero-flow
description: Find known research papers, retrieve lawful PDFs, organize them in Zotero, and optionally attach Chinese and bilingual translations on Windows. Use for an end-to-end paper workflow; use narrower sibling skills for one stage only.
---

# Paper Zotero Flow

Compose the installed paper skills through versioned JSON results. Call sibling entry scripts; do not import their implementation modules. Read each selected sibling's `SKILL.md` and relevant references before running its stage.

## Route the Request

- Find only: use `$paper-find`.
- Download or save: use `$paper-find`, `$paper-download`, then `$paper-zotero-ingest` by default.
- Download locally only: stop after `$paper-download`.
- Add an existing PDF: use `$paper-zotero-ingest`.
- Translate an existing PDF or Zotero item: use `$paper-translate`, then `$paper-zotero-ingest` by default. Reuse the existing parent; never invent a replacement item.
- Full workflow: find, download, ingest the original, translate, then attach both outputs.
- Attachment repair: validate and reuse existing local translations, then attach and verify; do not call translation again.
- Status/check only: read actual files and Zotero attachments; do not start translation, upload, or recurring monitoring.

Never create a Zotero item when no verified original PDF exists. Treat one paper's failure as isolated in batch work.

Translation defaults to pinned PDFMathTranslate-next with Qwen-MT Flash, direct DashScope access, `1` QPS and one worker. Preserve the user's provider/fallback choice: pass `-TranslationFallback none` for Qwen-only requests. The configurable Bing fallback is best-effort and deprecated upstream, not an alternative solution to scanned PDFs. Disclose Alibaba Cloud text transfer before translation, and Microsoft text transfer before an authorized Bing fallback. Never introduce another model or engine implicitly.

Prefer PowerShell 7 (or pass its absolute path with `-PowerShellPath`), verify the runtime and required commands, and keep child windows hidden. Do not change the user's global proxy. Preserve originals, parent items, valid translation outputs and diagnostic records on failure.

## Completion and resumption

“Translated locally”, “attached”, and “verified in Zotero” are different outcomes. A translation request normally needs **both Chinese-only and bilingual PDFs**. Report completion only after fresh read-back verifies the requested collection, attachment roles, readable stored PDFs and matching SHA-256 hashes. Local-only work verifies the local outputs instead. Structural checks are not a claim of manual translation-quality or page-by-page layout review.

Resume the original run by ID. Inspect its manifest and live state first; never start another instance of an active run. Reuse unchanged verified originals and translations. An uncertain Zotero mutation permits read-only reconciliation, not automatic replay. One paper's known failure should not prevent independent papers from proceeding.

For background work, give the real running/stopped state and the run directory. Do not promise later notification unless an authorized follow-up mechanism exists. Estimates are approximate; a launched process is not a completed task.

Read [references/workflow-routing.md](references/workflow-routing.md) for stage ordering and resume behavior. Read [references/manifest-schema.md](references/manifest-schema.md) when validating or merging stage results.
