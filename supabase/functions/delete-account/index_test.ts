import { handle } from "./index.ts";

function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}
Deno.test("rejects missing authentication and wrong method without contacting Auth", async () => {
  assert((await handle(new Request("https://example.test", { method: "POST" }))).status === 401, "missing token");
  assert((await handle(new Request("https://example.test"))).status === 405, "wrong method");
});
Deno.test("deletes only the verified account and ignores a supplied victim ID", async () => {
  Deno.env.set("SUPABASE_URL", "https://motion-test.invalid");
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-service-role");
  const original = globalThis.fetch;
  const paths: string[] = [];
  globalThis.fetch = ((input: RequestInfo | URL) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    paths.push(new URL(url).pathname);
    if (url.endsWith("/auth/v1/user")) return Promise.resolve(Response.json({ id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" }));
    if (url.endsWith("/auth/v1/admin/users/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")) return Promise.resolve(Response.json({ id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" }));
    throw new Error("unexpected destination");
  }) as typeof fetch;
  try {
    const response = await handle(new Request("https://example.test", { method: "POST", headers: { Authorization: "Bearer test-token" }, body: JSON.stringify({ userId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" }) }));
    assert(response.status === 200, "valid request");
    assert(paths.join(",") === "/auth/v1/user,/auth/v1/admin/users/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "only verified user is deleted");
  } finally { globalThis.fetch = original; }
});
Deno.test("rejects invalid tokens without calling account deletion", async () => {
  Deno.env.set("SUPABASE_URL", "https://motion-test.invalid");
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-service-role");
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = (() => { calls++; return Promise.resolve(Response.json({ message: "invalid token" }, { status: 401 })); }) as typeof fetch;
  try {
    const response = await handle(new Request("https://example.test", { method: "POST", headers: { Authorization: "Bearer invalid" } }));
    assert(response.status === 401 && calls === 1, "must verify before deleting");
  } finally { globalThis.fetch = original; }
});
