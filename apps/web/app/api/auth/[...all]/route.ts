import {getAuth} from "../../../../lib/auth";
import {failure} from "../../../../lib/http";
export const runtime="nodejs";
async function handler(request:Request) {
  try {
    const response=await getAuth().handler(request);
    response.headers.set("Cache-Control","private, no-store");
    return response;
  } catch(error) {return failure(error);}
}
export {handler as GET,handler as POST};
