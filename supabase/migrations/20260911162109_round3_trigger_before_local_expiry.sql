UPDATE public.dispatch_config
SET round_3_trigger_after_sec = 360,
    updated_at = now()
WHERE config_code = 'DEFAULT_V1'
  AND is_active = true
  AND round_3_trigger_after_sec IS DISTINCT FROM 360;
