export function publicEnv() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "";
  const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? "";
  return { url, key, configured: Boolean(url && key) };
}

export function appUrl() {
  return process.env.NEXT_PUBLIC_APP_URL || "http://localhost:3000";
}
