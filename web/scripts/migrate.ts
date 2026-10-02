import {readFile} from "node:fs/promises";
import {fileURLToPath} from "node:url";
import {createHash} from "node:crypto";
import {getPool} from "../lib/db";
async function main() {
 const pool=getPool(), c=await pool.connect();
 try {
  await c.query("begin"); await c.query("select pg_advisory_xact_lock(481681805)");
  await c.query("create table if not exists public.motion_server_migrations(name text primary key, sha256 text not null, applied_at timestamptz not null default now())");
  await c.query("revoke all on public.motion_server_migrations from public, anon, authenticated");
  const name="001_backend.sql", sql=await readFile(fileURLToPath(new URL("../migrations/"+name,import.meta.url)),"utf8");
  const hash=createHash("sha256").update(sql).digest("hex");
  const prior=(await c.query("select sha256 from public.motion_server_migrations where name=$1",[name])).rows[0];
  if(prior && prior.sha256!==hash) throw new Error("Migration has changed after deployment.");
  if(!prior) {await c.query(sql); await c.query("insert into public.motion_server_migrations(name,sha256) values($1,$2)",[name,hash]);}
  await c.query("commit"); console.log("Motion database migration is current.");
 } catch {await c.query("rollback");throw new Error("Migration failed; transaction rolled back. Check schema and connection configuration.");}
 finally {c.release();await pool.end();}
}
main().catch(error=>{console.error(error.message);process.exitCode=1;});
