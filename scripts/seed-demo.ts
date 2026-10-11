import { readFileSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";

function loadEnv(path: string) {
  try {
    const text = readFileSync(path, "utf8");
    for (const line of text.split(/\r?\n/)) {
      const match = /^([A-Z0-9_]+)=(.*)$/.exec(line.trim());
      if (!match || process.env[match[1]]) continue;
      process.env[match[1]] = match[2].replace(/^["']|["']$/g, "");
    }
  } catch {
    // .env.local is optional when the variables are already exported.
  }
}

loadEnv(".env.local");

if (process.env.ALLOW_DEMO_SEED !== "1") {
  console.error("Demo seed is off. Set ALLOW_DEMO_SEED=1 in .env.local only for a development store.");
  process.exit(1);
}

const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) {
  console.error("NEXT_PUBLIC_SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required.");
  process.exit(1);
}

const admin = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
const { data: pharmacies, error: pharmacyError } = await admin.from("pharmacies").select("id, name").limit(1);
if (pharmacyError || !pharmacies?.length) {
  console.error(pharmacyError?.message ?? "Create the first owner at /setup before seeding.");
  process.exit(1);
}

const pharmacy = pharmacies[0];
const { data, error } = await admin.rpc("seed_demo", { p_pharmacy: pharmacy.id });
if (error) {
  console.error(error.message);
  process.exit(1);
}
console.log(`${pharmacy.name}: ${JSON.stringify(data)}`);
