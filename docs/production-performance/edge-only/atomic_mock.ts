export async function acceptOrderAtomically(...args: unknown[]){return await (globalThis as any).__atomicAccept(...args);}
