"use server";

import { redirect } from "next/navigation";
import { z } from "zod";
import { createClient } from "@/lib/supabase/server";
import { appUrl, publicEnv } from "@/lib/env";

const credentials = z.object({
  email: z.email("Enter a valid email."),
  password: z.string().min(8, "Use at least 8 characters."),
});

export async function login(formData: FormData) {
  const parsed = credentials.safeParse({
    email: formData.get("email"),
    password: formData.get("password"),
  });
  if (!parsed.success) return { ok: false as const, message: parsed.error.issues[0]?.message ?? "Check the form." };
  if (!publicEnv().configured) return { ok: false as const, message: "Supabase is not configured yet. Add the project URL and publishable key." };
  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword(parsed.data);
  if (error) return { ok: false as const, message: "Email or password is incorrect." };
  redirect("/dashboard");
}

export async function logout() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/login");
}

export async function requestPasswordReset(formData: FormData) {
  const email = z.email().safeParse(formData.get("email"));
  if (!email.success) return { ok: false as const, message: "Enter a valid email." };
  if (!publicEnv().configured) return { ok: false as const, message: "Supabase is not configured yet. Add the project URL and publishable key." };
  const supabase = await createClient();
  const { error } = await supabase.auth.resetPasswordForEmail(email.data, {
    redirectTo: `${appUrl()}/auth/callback?next=/reset-password`,
  });
  if (error) return { ok: false as const, message: "The reset email could not be sent." };
  return { ok: true as const, message: "If an account exists, a reset link is on its way." };
}

export async function updatePassword(formData: FormData) {
  const password = z.string().min(8).safeParse(formData.get("password"));
  if (!password.success) return { ok: false as const, message: "Use at least 8 characters." };
  if (!publicEnv().configured) return { ok: false as const, message: "Supabase is not configured yet. Add the project URL and publishable key." };
  const supabase = await createClient();
  const { error } = await supabase.auth.updateUser({ password: password.data });
  if (error) return { ok: false as const, message: "The password could not be updated. Open the reset link again." };
  redirect("/dashboard");
}
