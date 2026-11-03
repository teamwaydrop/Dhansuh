-- Approved hardening fix: pin search_path on the phone-normalisation helper
-- (advisor: function_search_path_mutable). No body/signature/behaviour change.
ALTER FUNCTION public._normalize_in_phone_10(text) SET search_path = 'public';
