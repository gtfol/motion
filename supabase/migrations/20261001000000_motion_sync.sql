-- Private account data. Only the versioned RPCs may write; clients cannot bypass CAS.
create sequence public.motion_revision_seq;
create table public.motion_records (
  owner uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('exercise', 'routine', 'workout', 'preferences')),
  id uuid not null,
  revision bigint not null default nextval('public.motion_revision_seq'),
  body jsonb,
  primary key (owner, kind, id),
  check (body is null or jsonb_typeof(body) = 'object')
);
create index motion_records_cursor on public.motion_records(owner, revision);
create table public.motion_mutations (
  owner uuid not null references auth.users(id) on delete cascade,
  mutation_id uuid not null,
  request jsonb not null,
  result jsonb not null,
  primary key (owner, mutation_id)
);
alter table public.motion_records enable row level security;
alter table public.motion_mutations enable row level security;
create policy motion_read_own on public.motion_records for select to authenticated using (owner = (select auth.uid()));
revoke all on public.motion_records, public.motion_mutations from anon, authenticated;
revoke all on sequence public.motion_revision_seq from anon, authenticated;
grant select on public.motion_records to authenticated;

create function public.motion_pull(after_revision bigint default 0, page_size integer default 100)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); result jsonb;
begin
  if uid is null then raise exception 'authentication required' using errcode = '28000'; end if;
  if after_revision < 0 or page_size not between 1 and 100 then raise exception 'invalid cursor'; end if;
  select coalesce(jsonb_agg(to_jsonb(r) - 'owner' order by r.revision), '[]'::jsonb) into result
  from (select * from public.motion_records where owner = uid and revision > after_revision
        order by revision limit page_size) r;
  return result;
end $$;

create function public.motion_get(record_kind text, record_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); result jsonb;
begin
  if uid is null then raise exception 'authentication required' using errcode = '28000'; end if;
  select to_jsonb(r) - 'owner' into result from public.motion_records r
  where owner = uid and kind = record_kind and id = record_id;
  return result;
end $$;

create function public.motion_apply(mutation_id uuid, record_kind text, record_id uuid, expected_revision bigint, document jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); existing public.motion_records; previous public.motion_mutations;
  request jsonb; result jsonb;
begin
  if uid is null then raise exception 'authentication required' using errcode = '28000'; end if;
  if mutation_id is null or record_id is null or expected_revision is null or expected_revision < 0
     or record_kind is null or record_kind not in ('exercise','routine','workout','preferences')
     or (document is not null and (jsonb_typeof(document) <> 'object' or octet_length(document::text) > 8388608))
     or (record_kind = 'preferences' and record_id <> '453ca844-9412-43e5-95a4-862faeab4686') then
    raise exception 'invalid document';
  end if;
  -- Serialize before allocating revisions: a pull cursor must never skip a later commit
  -- with a smaller revision. Hash collisions only serialize unrelated accounts harmlessly.
  perform pg_advisory_xact_lock(hashtextextended(uid::text, 0));
  request := jsonb_build_object('kind',record_kind,'id',record_id,'expected',expected_revision,'body',document);
  select * into previous from public.motion_mutations m where m.owner = uid and m.mutation_id = motion_apply.mutation_id;
  if found then
    if previous.request <> request then raise exception 'mutation id reused'; end if;
    return previous.result;
  end if;
  select * into existing from public.motion_records r where r.owner = uid and r.kind = record_kind and r.id = record_id;
  if coalesce(existing.revision, 0) <> expected_revision then
    return jsonb_build_object('applied',false,'record',to_jsonb(existing) - 'owner');
  end if;
  insert into public.motion_records(owner,kind,id,body) values(uid,record_kind,record_id,document)
    on conflict(owner,kind,id) do update set body = excluded.body, revision = excluded.revision
    returning * into existing;
  result := jsonb_build_object('applied',true,'record',to_jsonb(existing) - 'owner');
  insert into public.motion_mutations values(uid,mutation_id,request,result);
  return result;
end $$;

revoke all on function public.motion_pull(bigint,integer), public.motion_get(text,uuid), public.motion_apply(uuid,text,uuid,bigint,jsonb) from public, anon;
grant execute on function public.motion_pull(bigint,integer), public.motion_get(text,uuid), public.motion_apply(uuid,text,uuid,bigint,jsonb) to authenticated;
