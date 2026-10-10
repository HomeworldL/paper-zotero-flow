# Result and Manifest Contracts

Every stage result contains `schema`, `schema_version`, `paper_id`, `status`, `inputs`, `outputs`, `provenance`, and `errors`.

Supported schemas are `paper-record.v1`, `download-result.v1`, `zotero-result.v1`, `translation-result.v1`, and `verification-result.v1`, all at schema version `1`. Existing stage schemas retain their version; the verification schema is additive.

The orchestrator is the only manifest writer. It validates a stage result before atomically merging the fields owned by that schema. Unknown schemas and versions leave the previous manifest unchanged.

Run state belongs under `%LOCALAPPDATA%\PaperZoteroFlow\runs\<run-id>`. Never place API keys, authorization keys, or translated document text in the manifest.

`translation-result.v1.outputs` records the verified artifacts, actual `service_used`, whether fallback was used, the primary failure in `fallback_reason`, and one timing record per provider attempt. The manifest retains these fields under `papers[].translation_run`, adds `total_duration_seconds`, and records the non-secret Qwen network, QPS, and worker settings. Credentials and source text must never be copied into the manifest.

The run records `requested_mode`, `local_only`, `requested_collection`, `run_state`, and `process_id`. `running` is a recorded state, not proof of current process liveness. Terminal states are `finished` or `finished_with_errors`.

Each paper records `stage_states`, `stage_history`, `last_stage_name`, `last_stage_status`, overall `status`, and `completion_verified`. `stage_states` separates find, download, ingest, translate, attach and verify. A successful stage does not overwrite the overall requested-workflow outcome. Legacy stage-only updater calls without a requested mode remain readable but do not establish end-to-end completion.

Failed translation attempts retain previous successful `translations`. `translation_run` describes the latest attempt; `artifact_translation_run` describes the successful attempt that produced the retained outputs. Diagnostic log **paths**, not log contents, may appear in these records.

`verification-result.v1.outputs` contains `verified`, `checked_at`, local-only scope, server/parent binding, per-role checks, and `certified_stages`. Fresh read-only verification can reconcile stages it actually proves. For Zotero this requires the live parent and readable stored files matching the expected role and SHA-256; local-only verification never certifies a Zotero upload. New stage activity invalidates prior completion verification.

An uncertain mutation is recorded as `unknown` on its actual stage and retained in history. It is not automatically replayed. `-Mode verify` records a distinct failure if a final read fails; it does not erase successful generation or attachment records. UTF-8 files and Local API response bytes are decoded explicitly, without passing JSON through console-code-page conversion.
