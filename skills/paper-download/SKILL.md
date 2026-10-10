---
name: paper-download
description: Retrieve and validate a lawful research-paper PDF from arXiv, Unpaywall, OpenAlex, a public URL, or an authorized Edge session. Use for paper PDFs; it does not itself mutate Zotero.
---

# Paper Download

Use `scripts/Download-Paper.ps1`. Prefer a successful `paper-record.v1`; DOI, arXiv ID, and direct URL also work.

Read [references/download-policy.md](references/download-policy.md) before choosing a source. When the result is `needs_browser`, follow [references/edge-fallback.md](references/edge-fallback.md).

An ordinary download or save request continues through `$paper-zotero-ingest` after verification. Stop locally only when the user explicitly asks. Never claim archival succeeded when that skill is absent or fails.
