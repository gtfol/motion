import type {Pool} from "pg";
import {z} from "zod";
import {authenticate,bearerHash,transaction} from "./native";
import {APIError,body,failure,json} from "./http";
const kind=z.enum(["exercise","routine","workout","preferences"]);
const uuid=z.uuid().transform(s=>s.toLowerCase());
const revision=z.number().int().min(0).max(Number.MAX_SAFE_INTEGER);
const pull=z.object({after_revision:revision,page_size:z.number().int().min(1).max(100)}).strict();
const get=z.object({record_kind:kind,record_id:uuid}).strict();
const apply=get.extend({mutation_id:uuid,expected_revision:revision,document:z.record(z.string(),z.unknown()).nullable()}).strict();
export function syncRoute(pool:Pool,action:string,request:Request) {
  return (async()=>{
    try {
      const hash=bearerHash(request);
      if(!["pull","get","apply"].includes(action)) throw new APIError("Not found.",404);
      // Vercel limits request bodies to 4.5 MB; use a lower explicit limit.
      const value=await body(request,4_000_000);
      const parsed=(action==="pull"?pull:action==="get"?get:apply).safeParse(value);
      if(!parsed.success) throw new APIError("Invalid sync request.");
      return json(await transaction(pool,async c=>{
        const user=await authenticate(c,hash);
        if(action==="pull") {const p=pull.parse(value);return (await c.query('select motion_backend.motion_pull($1,$2,$3) as result',[user.id,p.after_revision,p.page_size])).rows[0].result;}
        if(action==="get") {const p=get.parse(value);return (await c.query('select motion_backend.motion_get($1,$2,$3) as result',[user.id,p.record_kind,p.record_id])).rows[0].result;}
        const p=apply.parse(value);
        if(p.record_kind==="preferences" && p.record_id!=="453ca844-9412-43e5-95a4-862faeab4686") throw new APIError("Invalid preferences.");
        return (await c.query('select motion_backend.motion_apply($1,$2,$3,$4,$5,$6) as result',[user.id,p.mutation_id,p.record_kind,p.record_id,p.expected_revision,p.document===null?null:JSON.stringify(p.document)])).rows[0].result;
      }));
    } catch(error) {return failure(error);}
  })();
}
