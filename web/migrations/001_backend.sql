-- Private server schema: never expose this schema through the Supabase Data API.
create schema motion_backend;
revoke all on schema motion_backend from public, anon, authenticated;
alter default privileges in schema motion_backend revoke all on tables from public, anon, authenticated;
alter default privileges in schema motion_backend revoke all on sequences from public, anon, authenticated;
alter default privileges in schema motion_backend revoke execute on functions from public, anon, authenticated;
create table motion_backend."user" (
 id uuid primary key default gen_random_uuid(), name text not null, email text not null unique,
 "emailVerified" boolean not null default false, image text,
 "createdAt" timestamptz not null default now(), "updatedAt" timestamptz not null default now()
);
create table motion_backend."session" (
 id uuid primary key default gen_random_uuid(), "expiresAt" timestamptz not null, token text not null unique,
 "createdAt" timestamptz not null default now(), "updatedAt" timestamptz not null default now(),
 "ipAddress" text, "userAgent" text, "userId" uuid not null references motion_backend."user" on delete cascade
);
create index motion_session_user on motion_backend."session"("userId");
create table motion_backend.account (
 id uuid primary key default gen_random_uuid(), "accountId" text not null, "providerId" text not null,
 "userId" uuid not null references motion_backend."user" on delete cascade,
 "accessToken" text, "refreshToken" text, "idToken" text,
 "accessTokenExpiresAt" timestamptz, "refreshTokenExpiresAt" timestamptz, scope text, password text,
 "createdAt" timestamptz not null default now(), "updatedAt" timestamptz not null default now(),
 unique("providerId","accountId")
);
create index account_user on motion_backend.account("userId");
create table motion_backend.verification (
 id uuid primary key default gen_random_uuid(), identifier text not null, value text not null, "expiresAt" timestamptz not null,
 "createdAt" timestamptz not null default now(), "updatedAt" timestamptz not null default now()
);
create index verification_identifier on motion_backend.verification(identifier);
create table motion_backend."rateLimit" (id uuid primary key default gen_random_uuid(), key text not null unique, count integer not null, "lastRequest" bigint not null);
create table motion_backend.native_grants (
 hash text primary key, owner uuid not null references motion_backend."user" on delete cascade,
 session_id uuid not null references motion_backend."session" on delete cascade,
 challenge text not null check(length(challenge)=43), expires_at timestamptz not null
);
create index native_grants_owner on motion_backend.native_grants(owner);
create table motion_backend.native_tokens (
 id uuid primary key default gen_random_uuid(), owner uuid not null references motion_backend."user" on delete cascade,
 hash text not null unique, expires_at timestamptz not null
);
create index native_tokens_owner on motion_backend.native_tokens(owner);

create sequence motion_backend.motion_revision_seq;
create table motion_backend.motion_records (
  owner uuid not null references motion_backend."user"(id) on delete cascade,
  kind text not null check (kind in ('exercise', 'routine', 'workout', 'preferences')),
  id uuid not null,
  revision bigint not null default nextval('motion_backend.motion_revision_seq'),
  body jsonb,
  primary key (owner, kind, id),
  check (body is null or jsonb_typeof(body) = 'object')
);
create index motion_records_cursor on motion_backend.motion_records(owner, revision);
create table motion_backend.motion_mutations (
  owner uuid not null references motion_backend."user"(id) on delete cascade,
  mutation_id uuid not null,
  request jsonb not null,
  result jsonb not null,
  primary key (owner, mutation_id)
);
alter table motion_backend.motion_records enable row level security;
alter table motion_backend.motion_mutations enable row level security;
create function motion_backend.motion_pull(uid uuid, after_revision bigint default 0, page_size integer default 100)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare result jsonb;
begin
  if uid is null then raise exception 'authentication required' using errcode = '28000'; end if;
  if after_revision < 0 or page_size not between 1 and 100 then raise exception 'invalid cursor'; end if;
  -- Keep pages below Vercel's response limit, even with heart-rate-heavy workouts.
  select coalesce(jsonb_agg(document order by revision), '[]'::jsonb) into result
  from (
    select document, revision, row_number() over(order by revision) as position,
           sum(octet_length(document::text)) over(order by revision) as bytes
    from (select to_jsonb(r) - 'owner' as document, r.revision
          from motion_backend.motion_records r where owner = uid and revision > after_revision
          order by revision limit page_size) records
  ) bounded where bytes <= 3500000 or position = 1;
  return result;
end $$;

create function motion_backend.motion_get(uid uuid, record_kind text, record_id uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare result jsonb;
begin
  if uid is null then raise exception 'authentication required' using errcode = '28000'; end if;
  select to_jsonb(r) - 'owner' into result from motion_backend.motion_records r
  where owner = uid and kind = record_kind and id = record_id;
  return result;
end $$;

create function motion_backend.motion_apply(uid uuid, mutation_id uuid, record_kind text, record_id uuid, expected_revision bigint, document jsonb)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare existing motion_backend.motion_records; previous motion_backend.motion_mutations;
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
  select * into previous from motion_backend.motion_mutations m where m.owner = uid and m.mutation_id = motion_apply.mutation_id;
  if found then
    if previous.request <> request then raise exception 'mutation id reused'; end if;
    return previous.result;
  end if;
  select * into existing from motion_backend.motion_records r where r.owner = uid and r.kind = record_kind and r.id = record_id;
  if coalesce(existing.revision, 0) <> expected_revision then
    return jsonb_build_object('applied',false,'record',to_jsonb(existing) - 'owner');
  end if;
  insert into motion_backend.motion_records(owner,kind,id,body) values(uid,record_kind,record_id,document)
    on conflict(owner,kind,id) do update set body = excluded.body, revision = excluded.revision
    returning * into existing;
  result := jsonb_build_object('applied',true,'record',to_jsonb(existing) - 'owner');
  insert into motion_backend.motion_mutations values(uid,mutation_id,request,result);
  return result;
end $$;

-- Defense in depth even if a dashboard setting accidentally exposes this schema.
do $$ declare t record; begin
 for t in select tablename from pg_tables where schemaname='motion_backend' loop
  execute format('alter table motion_backend.%I enable row level security',t.tablename);
 end loop;
end $$;
revoke all on all tables in schema motion_backend from public, anon, authenticated;
revoke all on all sequences in schema motion_backend from public, anon, authenticated;
revoke all on all functions in schema motion_backend from public, anon, authenticated;
-- Legacy Supabase Auth data is retained in public; do not silently link identities by email.
