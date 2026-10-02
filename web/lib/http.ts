export class APIError extends Error {
  constructor(message:string, readonly status=400) { super(message); }
}
export const privateHeaders = {"Cache-Control":"private, no-store", "Referrer-Policy":"no-referrer"};
export const json = (value:unknown,status=200) => Response.json(value,{status,headers:privateHeaders});
export function failure(error:unknown) {
  return error instanceof APIError ? json({error:error.message},error.status) : json({error:"Motion is temporarily unavailable. Try again."},503);
}
export function nativeOnly(request:Request) {
  if (request.headers.has("origin") || request.headers.get("sec-fetch-site") === "cross-site") throw new APIError("Return to Motion to continue.",403);
}
export async function body(request:Request,limit=2048):Promise<unknown> {
  if (!request.headers.get("content-type")?.startsWith("application/json")) throw new APIError("Send JSON.",415);
  const reader=request.body?.getReader();
  if (!reader) throw new APIError("Missing request.");
  const parts:Uint8Array[]=[]; let size=0;
  try {
    for (;;) {
      const part=await reader.read(); if(part.done) break;
      size+=part.value.byteLength;
      if(size>limit) { await reader.cancel(); throw new APIError("Request is too large.",413); }
      parts.push(part.value);
    }
    return JSON.parse(Buffer.concat(parts).toString("utf8"));
  } catch(error) { if(error instanceof APIError) throw error; throw new APIError("Invalid request."); }
  finally { reader.releaseLock(); }
}
