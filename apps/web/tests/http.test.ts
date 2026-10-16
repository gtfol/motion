import test from "node:test";
import assert from "node:assert/strict";
import {APIError,failure} from "../lib/http";

test("server diagnostics never expose database or user details", async (t)=>{
  const log=t.mock.method(console,"error",()=>{});
  const secret="postgresql://private:password@database/private-user";
  const result=failure(Object.assign(new Error(secret),{code:"28P01",detail:secret}));
  assert.equal(result.status,503);
  assert.equal(result.headers.get("Cache-Control"),"private, no-store");
  assert.equal((await result.text()).includes(secret),false);
  assert.deepEqual(log.mock.calls[0].arguments,["motion_backend_failure","28P01"]);
  failure({code:secret,message:secret});
  assert.deepEqual(log.mock.calls[1].arguments,["motion_backend_failure","UNKNOWN"]);
  assert.equal(failure(new APIError("Sign in again.",401)).status,401);
  assert.equal(log.mock.calls.length,2);
});
