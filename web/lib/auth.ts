import { betterAuth, type BetterAuthOptions } from "better-auth";
import { getPool } from "./db";
export const siteURL = () => process.env.BETTER_AUTH_URL || "https://motion.gtfol.dev";
export function configured() {
  return Boolean(process.env.DATABASE_URL && process.env.BETTER_AUTH_SECRET && process.env.GOOGLE_CLIENT_ID && process.env.GOOGLE_CLIENT_SECRET);
}
let instance: ReturnType<typeof betterAuth> | undefined;
export function getAuth() {
  if (!configured()) throw new Error("Sign-in is not configured.");
  const options: BetterAuthOptions = {
    logger:{disabled:true},
    appName:"Motion", baseURL:siteURL(), secret:process.env.BETTER_AUTH_SECRET,
    database:getPool(), trustedOrigins:[siteURL()],
    // Vercel overwrites this header with the connecting client address.
    advanced:{database:{generateId:"uuid"},ipAddress:{ipAddressHeaders:["x-forwarded-for"]}},
    emailAndPassword:{enabled:false},
    socialProviders:{google:{clientId:process.env.GOOGLE_CLIENT_ID!, clientSecret:process.env.GOOGLE_CLIENT_SECRET!, prompt:"select_account"}},
    account:{encryptOAuthTokens:true},
    rateLimit:{enabled:true, storage:"database", window:60, max:60},
  };
  return instance ??= betterAuth(options);
}
