export function serve(handler: (request: Request) => Promise<Response>) {
  (globalThis as any).__photoHandler = handler;
}
