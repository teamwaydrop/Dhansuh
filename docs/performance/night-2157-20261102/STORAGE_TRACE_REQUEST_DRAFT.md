# Support investigation draft — NOT SUBMITTED

Project: yvwpchffctiagevpqgwy. November2,2026,16:27–16:33:30 UTC (21:57–22:03:30 IST); baseline from16:25 UTC. Read-only investigation requested, no resize/restart/configuration/deployment authorization.

- Gateway Storage object POST: request01a19d18-f7ab-7082-9de2-c32bbf2ad598, event16:30:21.611 UTC,60,012 ms origin,HTTP504,32,079 request bytes. No matching Storage service record found in this bounded exact-ID query.
- Separate Storage upload: request01a19d1a-138f-7d2f-b8a7-a1fee8097527, event16:32:11.240 UTC,ABORTED RES,36,936.345 ms,response status missing,43,262 request bytes. These are different requests; please do not merge their durations.
- PostgreSQL application Supabase Storage API:16:32:32.720 UTC PID928561 and16:32:40.912 UTC PID928562,SQLSTATE57014,query ID-3348394660839987691. Normalized statement: INSERT storage.objects ON CONFLICT(bucket_id,name COLLATE C) WHERE archived_at IS NULL DO UPDATE,RETURNING replaced-object subqueries. Historical five completed calls average208.048 ms; not incident-causation evidence.
- Auth-shaped lookup cancellation at16:30:32.214 UTC,PID928738,query ID8074250554804319433,user-request cancellation; other users/rider/KYC requests22–27 seconds. Cron startup failures and PostgREST Warp timeouts follow.
- At16:57:21.05493 UTC, both exact failed object names had no active metadata rows. Names/content/owner values are omitted from this draft. No blob was fetched or deleted.

Please supply existing trace spans linking HTTP request IDs to Storage admission/body completion,S3 write, database pool acquisition, transaction/advisory/row/index/FK locks, backend PID/query ID, statement begin/cancel/rollback, response abort and orphan-blob cleanup. Clarify timestamp semantics and whether work continued after client/gateway abort. Provide actual Storage pool limits/queue/waits at onset and whether the two PIDs were related to either request.

Please correlate with CPU modes/steal/throttling,MemAvailable/reclaim/major faults/OOM,swap-in/out,system/data disk read/write latency/queue/IOPS/throughput/burst budget,connection admission and blocker history at highest retained resolution. Identify actual compute size. Earlier incidents:Nov1 16:22–16:34 UTC;Nov2 06:44–07:00 UTC and12:13–12:25 UTC. We seek common onset evidence, not a capacity diagnosis from cumulative statistics or a later idle snapshot.

No tokens, signed URLs, object names, photos, account rows or personal messages are included. This file is a draft only; no external message/ticket was sent.
