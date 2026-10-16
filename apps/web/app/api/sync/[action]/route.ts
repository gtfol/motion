import {getPool} from "../../../../lib/db";
import {syncRoute} from "../../../../lib/sync";
import {failure} from "../../../../lib/http";
export const runtime="nodejs";
export async function POST(request:Request,context:{params:Promise<{action:string}>}) {
  try{return await syncRoute(getPool(),(await context.params).action,request);}catch(error){return failure(error);}
}
