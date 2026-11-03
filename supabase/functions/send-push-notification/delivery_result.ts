import {fcmErrorCode} from './fcm_result.ts';
export type DeliveryOutcome = 'SENT'|'UNREGISTERED'|'PERMANENT'|'TRANSIENT'|'QUOTA'|'UNCERTAIN'|'SKIPPED';
export function deliveryOutcome(status: number, text: string): DeliveryOutcome {
  if (status>=200 && status<300) return 'SENT';
  if (fcmErrorCode(text)==='UNREGISTERED') return 'UNREGISTERED';
  if (status===429) return 'QUOTA';
  if (status===401 || status===500 || status===502 || status===503 || status===504) return 'TRANSIENT';
  return status===0 || status===408 ? 'UNCERTAIN' : 'PERMANENT';
}
export function retryAfter(value: string|null, now=Date.now()): number {
  if (!value) return 0;
  const seconds=/^\d+$/.test(value) ? Number(value) : (Date.parse(value)-now)/1000;
  return Number.isFinite(seconds) ? Math.max(0,Math.min(3600,Math.ceil(seconds))) : 0;
}
export function notificationAllowed(type: string,data: Record<string,unknown>,pref: Record<string,any>|null): boolean {
  if (!pref) return true;
  if (type==='chat_message') return pref.pref_chat_notifications!==false;
  if (type==='new_rating') return pref.pref_rating_notifications!==false;
  if (type==='admin_broadcast') return pref.pref_admin_notifications!==false;
  if (type==='order_assignment' || type==='order_status') {
    if (pref.pref_order_notifications===false) return false;
    if (type==='order_assignment') return true;
    const mode=pref.order_notification_mode || 'important_only';
    if (mode==='tracking_silent') return data.status==='cancelled';
    if (mode==='important_only') return ['accepted','rider_arrived','picked_up','rider_at_drop','completed','delivered','cancelled'].includes(String(data.status));
  }
  return true;
}
