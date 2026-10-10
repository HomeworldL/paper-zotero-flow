# Source Routing

Recognize DOI, arXiv ID, DOI/arXiv URL, and title input. Prefer exact identifiers to search.

Use Crossref as the authority for published DOI metadata, arXiv for preprint identity and version, and OpenAlex only to fill missing fields or add open-access locations. Keep both DOI and arXiv identifiers when they describe the same work.

Title search succeeds only when the best normalized-title similarity is at least `0.90` and leads the second result by at least `0.08`. Otherwise report ambiguity and stop.
