import {getAuth,siteURL} from "../../../../lib/auth";
import {getPool} from "../../../../lib/db";
import {nativeRoutes} from "../../../../lib/native";
import {failure,json} from "../../../../lib/http";
export const runtime="nodejs";
async function handler(request:Request,context:{params:Promise<{action:string}>}) {
  try {
    const {action}=await context.params;
    const routes=nativeRoutes(getPool(),r=>getAuth().api.getSession({headers:r.headers,query:{disableCookieCache:true}}),siteURL());
    if(request.method==="POST" && action==="authorize") return routes.authorize(request);
    if(request.method==="POST" && action==="exchange") return routes.exchange(request);
    if((request.method==="GET" || request.method==="DELETE") && action==="session") return routes.session(request);
    if(request.method==="POST" && action==="delete-account") return routes.deleteAccount(request);
    return json({error:"Not found."},404);
  } catch(error) {return failure(error);}
}
export {handler as GET,handler as POST,handler as DELETE};
