// Credentials remain in the Edge Function environment; the phone only holds a publishable key.
import { createClient } from "npm:@supabase/supabase-js@2.57.4";

export async function handle(request: Request): Promise<Response> {
  if (request.method !== "POST") return new Response(null, { status: 405 });
  const authorization = request.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return new Response(null, { status: 401 });
  const url = Deno.env.get("SUPABASE_URL")!;
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  // Verify with Auth on every request. Never trust a client-provided user ID or decode-only JWT.
  const { data: { user }, error } = await admin.auth.getUser(authorization.slice(7));
  if (error || !user) return new Response(null, { status: 401 });
  const { error: deletionError } = await admin.auth.admin.deleteUser(user.id);
  if (deletionError) return new Response(null, { status: 500 });
  return Response.json({ deleted: true });
}

if (import.meta.main) Deno.serve(handle);
