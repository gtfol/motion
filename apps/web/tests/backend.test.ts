import {after,test} from "node:test";
import assert from "node:assert/strict";
import {randomBytes,randomUUID} from "node:crypto";
import {Pool} from "pg";
import {betterAuth,type BetterAuthOptions} from "better-auth";
import {nativeRoutes,challengeFor,digest} from "../lib/native";
import {syncRoute} from "../lib/sync";
import {databasePoolConfig} from "../lib/db";

const database=process.env.TEST_DATABASE_URL;
if(!database || !new URL(database).pathname.endsWith("_test") || !["localhost","127.0.0.1"].includes(new URL(database).hostname)) throw new Error("Use an explicit local TEST_DATABASE_URL ending in _test.");
const pool=new Pool(databasePoolConfig(database));
const origin="https://motion.gtfol.dev";
const created:string[]=[];
after(async()=>{for(const id of created) await pool.query('delete from motion_backend."user" where id=$1',[id]);await pool.end();});
async function fixture() {
 const id=randomUUID(),session=randomUUID();created.push(id);
 await pool.query('insert into motion_backend."user"(id,name,email) values($1,$2,$3)',[id,"Test",`${id}@example.invalid`]);
 await pool.query(`insert into motion_backend."session"(id,token,"expiresAt","userId") values($1,$2,now()+interval '1 hour',$3)`,[session,randomUUID(),id]);
 const browser={user:{id,email:`${id}@example.invalid`},session:{id:session}};
 return {id,session,browser,routes:nativeRoutes(pool,async()=>browser,origin)};
}
function req(path:string,value?:unknown,token?:string,extra:Record<string,string>={},method="POST") {
 return new Request(origin+path,{method,headers:{...(value===undefined?{}:{"Content-Type":"application/json"}),...(token?{Authorization:`Bearer ${token}`}:{ }),...extra},...(value===undefined?{}:{body:JSON.stringify(value)})});
}
async function grant(f:Awaited<ReturnType<typeof fixture>>) {
 const verifier=randomBytes(32).toString("base64url"),state=randomBytes(32).toString("base64url");
 const response=await f.routes.authorize(req("/api/native/authorize",{state,code_challenge:challengeFor(verifier),expectedUserId:f.id},undefined,{origin}));
 assert.equal(response.status,200);
 const url=new URL((await response.json()).callbackURL);
 assert.equal(url.protocol,"dev.gtfol.vitals:");assert.equal(url.searchParams.get("state"),state);
 assert.deepEqual([...url.searchParams.keys()].sort(),["code","state"]);
 return {code:url.searchParams.get("code")!,code_verifier:verifier};
}
async function login(f:Awaited<ReturnType<typeof fixture>>) {
 const response=await f.routes.exchange(req("/api/native/exchange",await grant(f)));
 assert.equal(response.status,200);return (await response.json()).token as string;
}
function change(id=randomUUID(),document:unknown={title:"squat"},expected=0) {return {record_kind:"exercise",record_id:id,mutation_id:randomUUID(),expected_revision:expected,document};}
async function sync(action:string,token:string,value:unknown) {return syncRoute(pool,action,req(`/api/sync/${action}`,value,token));}

 test("TLS verification cannot be disabled by connection URL options",()=>{
 const config=databasePoolConfig("postgres://u:p@db.example.test/postgres?sslmode=no-verify&host=evil.test");
 assert.equal(config.host,"db.example.test");assert.deepEqual(config.ssl,{rejectUnauthorized:true});
 assert.throws(()=>databasePoolConfig("password-secret"),error=>error instanceof Error&&!error.message.includes("password-secret"));
 });
 test("Better Auth schema supports Google sign-in and UUID users",async()=>{
 const options:BetterAuthOptions={database:pool,secret:randomBytes(32).toString("hex"),baseURL:origin,advanced:{database:{generateId:"uuid"}},account:{encryptOAuthTokens:true},socialProviders:{google:{clientId:"test.apps.googleusercontent.com",clientSecret:"test-secret"}},rateLimit:{enabled:true,storage:"database"}};
 const auth=betterAuth(options),context=await auth.$context;
 const user=await context.internalAdapter.createUser({name:"Adapter test",email:`${randomUUID()}@example.invalid`,emailVerified:true},{method:"oauth"});created.push(user.id);
 assert.match(user.id,/^[a-f0-9-]{36}$/);
 const session=await context.internalAdapter.createSession(user.id);
 assert.ok(session);
 const response=await auth.handler(req("/api/auth/sign-in/social",{provider:"google",callbackURL:"/connect"},undefined,{origin,"x-forwarded-for":"192.0.2.1"}));
 assert.equal(response.status,200);
 const url=new URL((await response.json()).url);
 assert.equal(url.origin,"https://accounts.google.com");
 assert.equal(url.searchParams.get("redirect_uri"),origin+"/api/auth/callback/google");
 assert.ok(response.headers.get("set-cookie"));
 });
 test("authorization rejects cross-origin, logged-out, and changed accounts",async()=>{
 const f=await fixture(),value={state:"a".repeat(43),code_challenge:"b".repeat(43),expectedUserId:f.id};
 assert.equal((await f.routes.authorize(req("/api/native/authorize",value,undefined,{origin:"https://evil.test"}))).status,403);
 assert.equal((await f.routes.authorize(req("/api/native/authorize",{...value,expectedUserId:randomUUID()},undefined,{origin}))).status,409);
 assert.equal((await nativeRoutes(pool,async()=>null,origin).authorize(req("/api/native/authorize",value,undefined,{origin}))).status,401);
 });
 test("PKCE rejects stolen codes, cross-origin exchange, and repeated exchange",async()=>{
 const f=await fixture(),value=await grant(f);
 assert.equal((await f.routes.exchange(req("/api/native/exchange",{...value,code_verifier:"z".repeat(43)}))).status,400);
 assert.equal((await f.routes.exchange(req("/api/native/exchange",value,undefined,{origin}))).status,403);
 const result=await f.routes.exchange(req("/api/native/exchange",value));assert.equal(result.status,200);
 const token=(await result.json()).token;
 const saved=(await pool.query('select hash from motion_backend.native_tokens where owner=$1',[f.id])).rows[0].hash;
 assert.equal(saved,digest(token));assert.notEqual(saved,token);
 assert.equal((await f.routes.exchange(req("/api/native/exchange",value))).status,400);
 });
 test("expired grants and ended browser sessions cannot issue native tokens",async()=>{
 const f=await fixture(),expired=await grant(f);
 await pool.query("update motion_backend.native_grants set expires_at=now()-interval '1 second' where owner=$1",[f.id]);
 assert.equal((await f.routes.exchange(req("/api/native/exchange",expired))).status,400);
 const value=await grant(f);await pool.query('delete from motion_backend."session" where id=$1',[f.session]);
 assert.equal((await f.routes.exchange(req("/api/native/exchange",value))).status,400);
 });
 test("concurrent exchanges consume a grant exactly once",async()=>{
 const f=await fixture(),value=await grant(f);
 const responses=await Promise.all([f.routes.exchange(req("/api/native/exchange",value)),f.routes.exchange(req("/api/native/exchange",value))]);
 assert.deepEqual(responses.map(x=>x.status).sort(),[200,400]);
 });
 test("two devices restore one account while another account sees no records",async()=>{
 const f=await fixture(),other=await fixture(),one=await login(f),two=await login(f),alien=await login(other);
 const value=change();assert.equal((await sync("apply",one,value)).status,200);
 const pull=await sync("pull",two,{after_revision:0,page_size:100});const records=await pull.json();assert.equal(records.length,1);assert.equal(records[0].body.title,"squat");
 assert.deepEqual(await (await sync("pull",alien,{after_revision:0,page_size:100})).json(),[]);
 assert.equal(await (await sync("get",alien,{record_kind:"exercise",record_id:value.record_id})).json(),null);
 assert.equal((await sync("pull",alien,{after_revision:0,page_size:100,owner:f.id})).status,400);
 });
 test("retry is idempotent, stale edits conflict, deletions persist as tombstones",async()=>{
 const f=await fixture(),token=await login(f),value=change();
 const first=await (await sync("apply",token,value)).json();assert.equal(first.applied,true);
 assert.deepEqual(await (await sync("apply",token,value)).json(),first);
 const conflict=await (await sync("apply",token,change(value.record_id,{title:"stale"}))).json();assert.equal(conflict.applied,false);assert.equal(conflict.record.body.title,"squat");
 const removed=await (await sync("apply",token,change(value.record_id,null,first.record.revision))).json();assert.equal(removed.applied,true);assert.equal(removed.record.body,null);
 const restored=await (await sync("pull",token,{after_revision:first.record.revision,page_size:100})).json();assert.equal(restored.length,1);assert.equal(restored[0].body,null);
 });
 test("revoked and expired native tokens are rejected",async()=>{
 const f=await fixture(),token=await login(f);
 assert.equal((await f.routes.session(req("/api/native/session",undefined,token,{},"DELETE"))).status,200);
 assert.equal((await sync("pull",token,{after_revision:0,page_size:100})).status,401);
 const expired=await login(f);await pool.query("update motion_backend.native_tokens set expires_at=now()-interval '1 second' where hash=$1",[digest(expired)]);
 assert.equal((await f.routes.session(req("/api/native/session",undefined,expired,{},"GET"))).status,401);
 });
 test("account deletion cascades only caller data and revokes every device",async()=>{
 const f=await fixture(),other=await fixture(),token=await login(f),second=await login(f),otherToken=await login(other);
 await sync("apply",token,change());await sync("apply",otherToken,change());
 assert.equal((await f.routes.deleteAccount(req("/api/native/delete-account",{confirm:"delete",owner:other.id},token))).status,400);
 assert.equal((await f.routes.deleteAccount(req("/api/native/delete-account",{confirm:"delete"},token))).status,200);
 for(const table of ['native_tokens','native_grants','motion_records','motion_mutations']) assert.equal((await pool.query(`select count(*)::int as count from motion_backend.${table} where owner=$1`,[f.id])).rows[0].count,0);
 assert.equal((await sync("pull",second,{after_revision:0,page_size:100})).status,401);
 assert.equal((await (await sync("pull",otherToken,{after_revision:0,page_size:100})).json()).length,1);
 });
 test("anonymous and Supabase client roles cannot access the private schema",async()=>{
 for(const role of ["anon","authenticated"]){
  const c=await pool.connect();try {await c.query('begin');await c.query(`set local role ${role}`);await assert.rejects(c.query('select * from motion_backend.motion_records'),{code:"42501"});}finally{await c.query('rollback');c.release();}
 }
 });
 test("sync rejects malformed, oversized, and unauthenticated requests",async()=>{
 const f=await fixture(),token=await login(f);
 assert.equal((await sync("pull","invalid",{after_revision:0,page_size:100})).status,401);
 assert.equal((await sync("pull",token,{after_revision:-1,page_size:100})).status,400);
 assert.equal((await sync("apply",token,change(randomUUID(),{large:"x".repeat(4_000_000)}))).status,413);
 assert.equal((await sync("apply",token,{...change(),record_kind:"preferences"})).status,400);
 });

test("large pages stop below hosting limits and resume without skipped records",async()=>{
 const f=await fixture(),token=await login(f);
 for(let i=0;i<3;i++) assert.equal((await sync("apply",token,change(randomUUID(),{payload:"x".repeat(1_200_000)}))).status,200);
 let cursor=0,total=0;
 for(let page=0;page<4;page++) {
  const response=await sync("pull",token,{after_revision:cursor,page_size:100});
  const text=await response.text(); assert.ok(Buffer.byteLength(text)<4_000_000);
  const records=JSON.parse(text); if(!records.length) break;
  assert.ok(records[0].revision>cursor);total+=records.length;cursor=records.at(-1).revision;
 }
 assert.equal(total,3);
});
