import {createHash,randomBytes,randomUUID,timingSafeEqual} from "node:crypto";
import type {Pool,PoolClient} from "pg";
import {z} from "zod";
import {APIError,body,failure,json,nativeOnly} from "./http";
export const callbackURL="dev.gtfol.vitals://auth/callback";
export const opaque=z.string().regex(/^[A-Za-z0-9_-]{43}$/);
export const authorization=z.object({code_challenge:opaque,state:opaque}).strict();
const authorizeBody=authorization.extend({expectedUserId:z.uuid()}).strict();
const exchangeBody=z.object({code:opaque,code_verifier:z.string().regex(/^[A-Za-z0-9._~-]{43,128}$/)}).strict();
export const digest=(s:string)=>createHash("sha256").update(s).digest("hex");
export const challengeFor=(s:string)=>createHash("sha256").update(s).digest("base64url");
export type BrowserSession={user:{id:string;email:string};session:{id:string}};
export type User={id:string;email:string;name:string};
const invalid=()=>new APIError("Sign-in expired. Return to Motion and try again.");
export function bearerHash(request:Request) {
  nativeOnly(request);
  const value=request.headers.get("authorization");
  if(!value || !/^Bearer motion_[A-Za-z0-9_-]{43}$/.test(value)) throw new APIError("Sign in again.",401);
  return digest(value.slice(7));
}
// Lock the user before rechecking the token, so deletion/revocation and writes cannot race.
export async function authenticate(client:PoolClient,hash:string,exclusive=false):Promise<User> {
  const result=await client.query<User>(`select u.id,u.email,u.name from motion_backend."user" u join motion_backend.native_tokens t on t.owner=u.id where t.hash=$1 and t.expires_at>now() for ${exclusive?'update':'share'} of u`,[hash]);
  const user=result.rows[0];
  if(!user || !(await client.query('select 1 from motion_backend.native_tokens where hash=$1 and expires_at>now()',[hash])).rowCount) throw new APIError("Sign in again.",401);
  return user;
}
export async function transaction<T>(pool:Pool,work:(client:PoolClient)=>Promise<T>):Promise<T> {
  const client=await pool.connect();
  try { await client.query("begin"); const result=await work(client); await client.query("commit"); return result; }
  catch(error) { await client.query("rollback"); throw error; } finally {client.release();}
}
export function nativeRoutes(pool:Pool,sessionFor:(r:Request)=>Promise<BrowserSession|null>,origin:string) {
  return {
    async authorize(request:Request) {
      try {
        if(request.headers.get("origin")!==origin || request.headers.get("sec-fetch-site")==="cross-site") throw new APIError("Sign in from Motion.",403);
        const parsed=authorizeBody.safeParse(await body(request)); if(!parsed.success) throw invalid();
        const session=await sessionFor(request); if(!session) throw new APIError("Sign in first.",401);
        if(session.user.id!==parsed.data.expectedUserId) throw new APIError("Your account changed. Reload and try again.",409);
        const code=randomBytes(32).toString("base64url");
        await transaction(pool,async c=>{
          if(!(await c.query('select id from motion_backend."user" where id=$1 for update',[session.user.id])).rowCount) throw invalid();
          await c.query('delete from motion_backend.native_grants where owner=$1 and expires_at<=now()',[session.user.id]);
          const count=await c.query('select count(*)::int as count from motion_backend.native_grants where owner=$1',[session.user.id]);
          if(count.rows[0].count>=10) throw new APIError("Too many attempts. Try again in two minutes.",429);
          await c.query("insert into motion_backend.native_grants(hash,owner,session_id,challenge,expires_at) values($1,$2,$3,$4,now()+interval '2 minutes')",[digest(code),session.user.id,session.session.id,parsed.data.code_challenge]);
        });
        const url=new URL(callbackURL); url.searchParams.set("code",code);url.searchParams.set("state",parsed.data.state);
        return json({callbackURL:url.toString()});
      } catch(error) {return failure(error);}
    },
    async exchange(request:Request) {
      try {
        nativeOnly(request);
        const parsed=exchangeBody.safeParse(await body(request));if(!parsed.success) throw invalid();
        const result=await transaction(pool,async c=>{
          // All operations lock user first, including exchange, to avoid lock inversion with deletion.
          const owner=(await c.query('select owner from motion_backend.native_grants where hash=$1',[digest(parsed.data.code)])).rows[0]?.owner;
          if(!owner) throw invalid();
          const user=(await c.query<User>('select id,email,name from motion_backend."user" where id=$1 for update',[owner])).rows[0];
          const grant=(await c.query('select * from motion_backend.native_grants where hash=$1 and expires_at>now() for update',[digest(parsed.data.code)])).rows[0];
          if(!user || !grant || !timingSafeEqual(Buffer.from(grant.challenge),Buffer.from(challengeFor(parsed.data.code_verifier)))) throw invalid();
          if(!(await c.query('select id from motion_backend."session" where id=$1 and "userId"=$2 and "expiresAt">now()',[grant.session_id,owner])).rowCount) throw invalid();
          await c.query('delete from motion_backend.native_tokens where owner=$1 and expires_at<=now()',[owner]);
          const count=await c.query('select count(*)::int as count from motion_backend.native_tokens where owner=$1',[owner]);
          if(count.rows[0].count>=20) throw new APIError("Too many connected devices. Sign out on another device first.",409);
          const token="motion_"+randomBytes(32).toString("base64url");
          const saved=await c.query("insert into motion_backend.native_tokens(id,owner,hash,expires_at) values($1,$2,$3,now()+interval '1 year') returning expires_at",[randomUUID(),owner,digest(token)]);
          await c.query('delete from motion_backend.native_grants where hash=$1',[digest(parsed.data.code)]);
          return {token,user,expiresAt:saved.rows[0].expires_at};
        });
        return json(result);
      } catch(error) {return failure(error);}
    },
    async session(request:Request) {
      try {
        const hash=bearerHash(request);
        return json(await transaction(pool,async c=>{
          const user=await authenticate(c,hash,request.method==="DELETE");
          if(request.method==="DELETE") {await c.query('delete from motion_backend.native_tokens where hash=$1',[hash]);return {signedOut:true};}
          return {user};
        }));
      } catch(error) {return failure(error);}
    },
    async deleteAccount(request:Request) {
      try {
        const hash=bearerHash(request);
        const parsed=z.object({confirm:z.literal("delete")}).strict().safeParse(await body(request));
        if(!parsed.success) throw new APIError("Confirm account deletion.");
        await transaction(pool,async c=>{
          const user=await authenticate(c,hash,true);
          await c.query('delete from motion_backend."user" where id=$1',[user.id]);
        });
        return json({deleted:true});
      } catch(error) {return failure(error);}
    },
  };
}
