---
name: paper-zotero-ingest
description: Create or reuse a Zotero paper item, place it in a collection, and attach verified original or translated PDFs through Zotero 10 Local API. Use for Zotero paper writes, not read-only citation lookup.
---

# Paper Zotero Ingest

This skill is the sole owner of Zotero mutation in Paper Zotero Flow. Use `scripts/Invoke-ZoteroIngest.ps1` in `create-with-pdf` or `attach-to-item` mode.

Never create a parent from an unverified or missing original PDF. Request Zotero's local authorization only immediately before mutation; file upload requires **Always Allow** because it spans multiple writes.

Read [references/zotero-local-api.md](references/zotero-local-api.md) before changing request, upload, deduplication, or rollback behavior.
