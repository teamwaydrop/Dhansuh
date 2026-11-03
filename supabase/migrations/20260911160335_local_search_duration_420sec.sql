UPDATE public.dispatch_config
SET max_search_duration_sec = 420,
    updated_at = now()
WHERE config_code = 'DEFAULT_V1'
  AND is_active = true
  AND max_search_duration_sec IS DISTINCT FROM 420;
