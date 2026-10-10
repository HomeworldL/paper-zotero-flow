---
name: paper-find
description: Resolve a known research paper from a title, DOI, arXiv identifier, or paper URL into canonical metadata and lawful PDF candidates. Use for identification, not recommendations or scientific review.
---

# Paper Find

Run `scripts/Resolve-Paper.ps1` for each requested paper. A successful result is `paper-record.v1` with identifiers, canonical metadata, lawful PDF candidates, and provenance.

Stop when identity is ambiguous or unresolved. Return the checked sources and candidates; do not guess, recommend papers, download files, or write Zotero.

Read [references/source-routing.md](references/source-routing.md) when choosing metadata authority or merging an arXiv preprint with a published DOI.
