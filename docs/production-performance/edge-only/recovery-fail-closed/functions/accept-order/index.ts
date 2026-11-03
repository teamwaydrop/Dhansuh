// Emergency availability rollback: no imports, secrets, reads or writes.
Deno.serve((request: Request) => {
  const headers = {'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Retry-After':'30'};
  return request.method === 'OPTIONS' ? new Response('ok',{headers}) : Response.json({success:false,retryable:true,message:'Acceptance is temporarily unavailable. Please retry.'},{status:503,headers});
});
