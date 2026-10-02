import { Pool, type PoolConfig } from "pg";

let pool: Pool | null = null;
export function dbConfigured(): boolean { return Boolean(process.env.DATABASE_URL); }

export function databasePoolConfig(connectionString: string, ca?: string, poolMax?: string): PoolConfig {
  let url: URL;
  let user: string;
  let password: string;
  let database: string;
  try {
    url = new URL(connectionString);
    if (!['postgres:', 'postgresql:'].includes(url.protocol) || !url.hostname) throw new Error();
    user = decodeURIComponent(url.username);
    password = decodeURIComponent(url.password);
    database = decodeURIComponent(url.pathname.slice(1));
  } catch {
    // URL parser errors can contain the connection string and its password.
    throw new Error("DATABASE_URL must be a valid Postgres connection URL.");
  }
  const host = url.hostname.replace(/^\[|\]$/g, "").toLowerCase();
  const local = host === "localhost" || host === "127.0.0.1" || host === "::1";
  const certificate = ca?.replace(/\\n/g, "\n").trim();
  const max = Number(poolMax);
  return {
    // Explicit fields prevent pg from reparsing URL query options such as
    // sslmode=require, ssl=no-verify, or host= and replacing these settings.
    host, user, password, database,
    options: "-c search_path=motion_backend",
    port: url.port ? Number(url.port) : 5432,
    max: Number.isInteger(max) && max > 0 && max <= 50 ? max : 5,
    connectionTimeoutMillis: 10_000,
    idleTimeoutMillis: 20_000,
    ssl: local ? false : { rejectUnauthorized: true, ...(certificate ? { ca: certificate } : {}) },
  };
}

export function getPool(): Pool {
  if (pool) return pool;
  const connectionString = process.env.DATABASE_URL;
  if (!connectionString) throw new Error("DATABASE_URL is not configured.");
  pool = new Pool(databasePoolConfig(connectionString, process.env.DATABASE_SSL_CA, process.env.DATABASE_POOL_MAX));
  return pool;
}
