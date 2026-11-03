// Real remote dependency graph; no production request or deployed function invocation.
import {createClient} from 'https://esm.sh/@supabase/supabase-js@2';
import assert from 'node:assert/strict';
Deno.test('locked Supabase dependency constructs an inert local client',()=>{
  const client=createClient('http://127.0.0.1:54328','synthetic-key',{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}});
  const query=client.from('users').select('id');
  assert.equal((query as any).url.hostname,'127.0.0.1');
});
