# Draft only — not submitted

Project: `yvwpchffctiagevpqgwy`. Please investigate a Storage upload failing with DatabaseTimeout while unrelated database/Realtime operations also degrade. Do not change settings or initiate paid resources without the project owner's approval.

Window: November 2, 2026, **15:20–15:35 UTC / 20:50–21:05 IST**. Critical upload approximately **15:28:44–15:29:18 UTC / 20:58:44–20:59:18 IST**.

Gateway records a pickup-proof object upload at 15:28:44.503 UTC, 566,848 request bytes, origin duration **33,209 ms**, HTTP **544**. Storage service records `storage.object.upload`, `error.errorCode=DatabaseTimeout`, error status **544**, execution time **33,200 ms**, response time **33,200.283 ms**, at 15:29:17.721 UTC. Its raw error includes **PostgreSQL 57014**. PostgreSQL application `Supabase Storage API` logs a statement timeout at **15:29:17.636 UTC**, but the parsed query text is absent. The events are tightly time-correlated; no cross-service request ID was captured in this investigation.

Two other object uploads in the window succeeded but took 16,111 ms (52,852 request bytes) and 15,094 ms (437,821 request bytes). These are request sizes, not decoded-image sizes. No image content, object paths, order/user identifiers, IPs, credentials or tokens are included here.

Please identify:

1. The actual Storage database statement and wait category: lock, I/O, execution or connection acquisition; the source of the statement timeout and the internal pool's occupancy/queue at onset.
2. Whether any platform event or constrained shared resource explains simultaneous Realtime subscription timeouts and REST read tails.
3. Historical available memory/paging, per-device disk latency/IOPS/queue and I/O budget, CPU modes and active/waiting connections for this window, especially before the timeout.
4. Whether the failed upload's metadata/object write was committed, rolled back or left ambiguous. Do not delete objects or change proof records as a diagnostic action.

Later read-only metadata at 21:23 IST showed max_connections 60, 13 idle client connections and no blocked backend. This later state does not establish peak usage. Role `supabase_storage_admin` has no separate rolconnlimit and no role-level statement_timeout in the returned rolconfig; service pool size/session timeout settings remain unknown. We have not increased pool size or timeouts, deployed changes, restarted services or performed production EXPLAIN ANALYZE.

We have not established CPU/RAM/I/O as the initiating cause. An independent public-table RLS optimization is locally tested but remains unapplied; we do not assume it repairs this unidentified Storage statement.
