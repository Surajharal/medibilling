import { redirect } from "next/navigation";
import { publicEnv } from "@/lib/env";
import { createClient } from "@/lib/supabase/server";

export default async function HomePage() {
  if (!publicEnv().configured) redirect("/login");
  const supabase = await createClient();
  const { data } = await supabase.auth.getUser();
  redirect(data.user ? "/dashboard" : "/login");
}
