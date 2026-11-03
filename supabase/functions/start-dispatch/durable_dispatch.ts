type Client = { rpc: (name: string, args: Record<string, unknown>) => PromiseLike<{data: any; error: any}> };

export async function dispatchRpc(client: Client, name: string, args: Record<string, unknown>) {
  const {data, error} = await client.rpc(name, args);
  if (error) throw new Error('DISPATCH_STORAGE_UNAVAILABLE');
  return data;
}

/** Each step owns a different DB generation; sleep never holds a lease/SQL lock. */
export async function runDurableDispatch(client: Client, orderId: string, options: {
  now?: () => number; sleep?: (ms: number) => Promise<void>; budgetMs?: number;
} = {}) {
  const now = options.now ?? Date.now;
  const sleep = options.sleep ?? ((ms) => new Promise<void>((r) => setTimeout(r, ms)));
  const end = now() + (options.budgetMs ?? 85000);
  let steps = 0, offers = 0;
  while (now() < end) {
    const claim = await dispatchRpc(client, 'claim_order_dispatch', {p_order_id: orderId});
    if (!claim?.claimed) {
      const wait = Math.min(15000, Math.max(0, Number(claim?.wait_ms) || 0));
      if (wait>0 && now()+wait<end) { await sleep(Math.max(100,wait)); continue; }
      return {success: true, steps, offers, coalesced: true};
    }
    try {
      const result = await dispatchRpc(client, 'step_order_dispatch', {p_order_id: orderId, p_token: claim.token});
      if (!result?.applied) return {success: true, steps, offers, stopped: result?.code};
      steps++; offers += Number(result.offers) || 0;
      const wait = Math.max(1000, Math.min(15000, Number(result.next_ms) || 15000));
      if (now() + wait >= end) break;
      await sleep(wait);
    } catch (error) {
      // A lost step response may mean COMMIT already happened. Release is token
      // checked; it cannot undo that commit or a replacement worker's state.
      try { await dispatchRpc(client, 'release_order_dispatch', {p_order_id: orderId, p_token: claim.token}); } catch (_) { /* durable lease/recovery owns liveness */ }
      throw error;
    }
  }
  return {success: true, steps, offers, recovery_pending: true};
}
