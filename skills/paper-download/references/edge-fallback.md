# Edge Fallback

Use Edge only when deterministic lawful sources fail and the user already has access. Navigate to the publisher or repository page, let the user complete any login, and save the PDF into the current run directory.

Inspect the first page for title, DOI, or arXiv agreement. Resume `Download-Paper.ps1` with `-CandidateFile` and `-IdentityConfirmed` only after that check.

Do not click Zotero Connector or create a library item during retrieval. If no PDF can be saved, return failure and create no Zotero item.
