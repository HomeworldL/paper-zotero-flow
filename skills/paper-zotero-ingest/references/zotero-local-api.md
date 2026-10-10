# Zotero 10 Local API Rules

Use `http://127.0.0.1:23119/api/`. Probe the root and bind every write to its `Zotero-Server-ID`. Reads are unauthenticated; writes carry a key returned by `POST /api/local/authorize`.

Store remembered keys only through Windows DPAPI CurrentUser, partitioned by Server ID. Never put a key in a URL, result, manifest, prompt, or log. Do not silently reopen the authorization dialog after denial, rate limiting, `401`, or an unknown write outcome.

Stored files use attachment creation followed by upload authorization, byte upload, and registration. Before sending bytes, require the upload URL to remain on the configured loopback port. A one-shot Allow key is insufficient; require Always Allow.

Search DOI, arXiv ID, then normalized title before creation. Deduplicate attachments by semantic role and SHA-256. Roll back only objects known to have been created by the current attempt, never a pre-existing parent.

For more than one attachment from a command-line caller, write a JSON array of `{ "path": "...", "role": "..." }` objects and use `-AttachmentListPath`. This preserves spaces and semicolons and avoids Windows PowerShell 5.1 array-binding ambiguity.
