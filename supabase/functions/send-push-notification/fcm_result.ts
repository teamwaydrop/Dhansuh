// Provider messages may echo request data. Retain only a known structured code.
export function fcmErrorCode(text: string): string {
  try {
    const details = JSON.parse(text)?.error?.details;
    if (Array.isArray(details)) {
      const code = details.find((entry) =>
        entry?.['@type'] === 'type.googleapis.com/google.firebase.fcm.v1.FcmError'
      )?.errorCode;
      if (['UNREGISTERED', 'INVALID_ARGUMENT', 'SENDER_ID_MISMATCH',
        'QUOTA_EXCEEDED', 'UNAVAILABLE', 'INTERNAL', 'THIRD_PARTY_AUTH_ERROR'].includes(code)) {
        return code;
      }
    }
  } catch (_) { /* A non-JSON response is not evidence that a token expired. */ }
  return 'FCM_HTTP_ERROR';
}
