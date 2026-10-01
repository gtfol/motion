\set ON_ERROR_STOP on
begin;
create function public.test_assert(ok boolean, description text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL: %', description; end if; end $$;
set role authenticated;
select set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',false);
select public.motion_apply('11111111-1111-4111-8111-111111111111','workout','22222222-2222-4222-8222-222222222222',0,'{"sets":1}') as original \gset
select public.test_assert((:'original'::jsonb->>'applied')::boolean,'initial create');
select public.test_assert(public.motion_apply('11111111-1111-4111-8111-111111111111','workout','22222222-2222-4222-8222-222222222222',0,'{"sets":1}') = :'original'::jsonb,'lost acknowledgement retry is idempotent');
select public.test_assert(jsonb_array_length(public.motion_pull())=1,'retry does not duplicate');
select public.test_assert((public.motion_apply('33333333-3333-4333-8333-333333333333','workout','22222222-2222-4222-8222-222222222222',0,'{"sets":2}')->>'applied')::boolean = false,'stale edits conflict');
do $$ begin
  perform public.motion_apply('11111111-1111-4111-8111-111111111111','workout','22222222-2222-4222-8222-222222222222',0,'{"sets":3}');
  raise exception 'reused mutation accepted';
exception when raise_exception then if sqlerrm <> 'mutation id reused' then raise; end if; end $$;
do $$ begin
  update public.motion_records set body = '{}'::jsonb;
  raise exception 'direct write accepted';
exception when insufficient_privilege then null; end $$;
do $$ begin
  perform public.motion_apply(gen_random_uuid(),'unknown',gen_random_uuid(),0,'{}');
  raise exception 'invalid kind accepted';
exception when raise_exception then if sqlerrm <> 'invalid document' then raise; end if; end $$;
select set_config('request.jwt.claim.sub','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',false);
select public.test_assert(jsonb_array_length(public.motion_pull())=0,'second account cannot pull first account');
select public.test_assert(public.motion_get('workout','22222222-2222-4222-8222-222222222222') is null,'second account cannot get first account');
select public.test_assert((select count(*)=0 from public.motion_records),'RLS hides first account rows');
select public.test_assert((public.motion_apply('11111111-1111-4111-8111-111111111111','workout','22222222-2222-4222-8222-222222222222',0,'{"sets":9}')->>'applied')::boolean,'same IDs are independent per account');
select set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',false);
select public.motion_apply(gen_random_uuid(),'workout','22222222-2222-4222-8222-222222222222',(:'original'::jsonb#>>'{record,revision}')::bigint,null) as deletion \gset
select public.test_assert((:'deletion'::jsonb->>'applied')::boolean,'deletion succeeds');
select public.test_assert(:'deletion'::jsonb#>'{record,body}' = 'null'::jsonb,'deletion keeps tombstone');
select public.test_assert((public.motion_apply(gen_random_uuid(),'workout','22222222-2222-4222-8222-222222222222',(:'original'::jsonb#>>'{record,revision}')::bigint,'{"sets":4}')->>'applied')::boolean = false,'offline edit cannot resurrect deletion');
select public.test_assert(jsonb_array_length(public.motion_pull((:'original'::jsonb#>>'{record,revision}')::bigint,1))=1,'cursor returns deletion');
select public.test_assert(jsonb_array_length(public.motion_pull((:'deletion'::jsonb#>>'{record,revision}')::bigint,1))=0,'cursor catches up');
select set_config('request.jwt.claim.sub','',false);
do $$ begin
  perform public.motion_pull();
  raise exception 'unauthenticated pull accepted';
exception when invalid_authorization_specification then null; end $$;
reset role;
select public.test_assert(not has_function_privilege('anon','public.motion_pull(bigint,integer)','EXECUTE'),'anonymous RPC denied');
delete from auth.users where id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select public.test_assert((select count(*)=0 from public.motion_records where owner='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),'account deletion cascades records');
select public.test_assert((select count(*)=0 from public.motion_mutations where owner='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),'account deletion cascades deduplication history');
rollback;
\echo 'All sync database assertions passed.'
