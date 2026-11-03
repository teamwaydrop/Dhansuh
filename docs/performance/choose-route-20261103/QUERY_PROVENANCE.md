# Read-only evidence queries

Executed through Supabase query_logs with project_id=yvwpchffctiagevpqgwy, iso_timestamp_start=2026-11-03T04:24:00Z, iso_timestamp_end=2026-11-03T04:34:00Z. The tool enforces this interval; it is not embedded in the SQL. Five bounded log queries total; no broad historical scans.

## choose_LOG_SUMMARY_QUERY

```sql
SELECT source,count() AS n,max(if(source='function_edge_logs',toFloat64OrZero(log_attributes['execution_time_ms']),toFloat64OrZero(log_attributes['response.origin_time']))) AS max_ms,countIf(source='edge_logs' AND toInt32OrZero(log_attributes['response.status_code'])>=500) AS http5xx,countIf(positionCaseInsensitive(event_message,'timeout')>0 OR log_attributes['parsed.sql_state_code']='57014') AS timeout_records FROM logs GROUP BY source ORDER BY source
```

## choose_ENDPOINT_QUERY

```sql
SELECT source,path,status,count() AS n,round(quantileExact(0.5)(ms),1) AS p50_ms,round(quantileExact(0.95)(ms),1) AS p95_ms,max(ms) AS max_ms FROM (SELECT source,if(source='function_edge_logs',log_attributes['request.pathname'],splitByChar('?',log_attributes['request.path'])[1]) AS path,log_attributes['response.status_code'] AS status,if(source='function_edge_logs',toFloat64OrZero(log_attributes['execution_time_ms']),toFloat64OrZero(log_attributes['response.origin_time'])) AS ms FROM logs WHERE source IN ('edge_logs','function_edge_logs')) WHERE path IN ('/functions/v1/calculate-order-pricing','/calculate-order-pricing','/rest/v1/pricing_config','/rest/v1/pricing_zones','/rest/v1/dispatch_config','/rest/v1/riders','/rest/v1/production_config','/rest/v1/rpc/find_nearby_riders','/auth/v1/user') OR (source='function_edge_logs' AND position(path,'calculate-order-pricing')>0) GROUP BY source,path,status ORDER BY max_ms DESC
```

## choose_TIMELINE_QUERY

```sql
SELECT toStartOfMinute(e.timestamp) AS minute_utc,if(v.vehicle='','unknown',v.vehicle) AS vehicle,count() AS n,min(e.ms) AS min_ms,max(e.ms) AS max_ms FROM (SELECT timestamp,log_attributes['execution_id'] AS execution_id,toFloat64OrZero(log_attributes['execution_time_ms']) AS ms FROM logs WHERE source='function_edge_logs' AND log_attributes['function_id']='14820d31-73bf-4edb-ba38-b6a873520108') e LEFT JOIN (SELECT log_attributes['execution_id'] AS execution_id,anyIf(extract(event_message, '"vehicle_type": *"([^"]+)"'),extract(event_message, '"vehicle_type": *"([^"]+)"') IN ('bike','auto','cab')) AS vehicle FROM logs WHERE source='function_logs' GROUP BY execution_id) v ON e.execution_id=v.execution_id GROUP BY minute_utc,vehicle ORDER BY minute_utc,vehicle
```


