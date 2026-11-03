export function createClient(..._args: unknown[]) { return (globalThis as any).__pricingClient; }
export function serve(handler: (request: Request) => Promise<Response>) { (globalThis as any).__pricingHandler = handler; }
