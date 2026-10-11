"use client";

import { useActionState } from "react";
import { INDIAN_STATES } from "@/lib/catalog";
import { Button } from "@/components/ui/button";
import { Field, Input, Select } from "@/components/ui/inputs";
import { bootstrapStore } from "@/server/operations";

export default function SetupPage() {
  const [state, action, pending] = useActionState(async (_prev: { message?: string; ok?: boolean } | null, formData: FormData) => {
    return bootstrapStore({
      secret: formData.get("secret"),
      pharmacy_name: formData.get("pharmacy_name"),
      owner_name: formData.get("owner_name"),
      email: formData.get("email"),
      password: formData.get("password"),
      state: INDIAN_STATES.find((item) => item.code === formData.get("state_code"))?.name ?? "",
      state_code: formData.get("state_code"),
      gstin: formData.get("gstin"),
    });
  }, null);
  return (
    <main className="mx-auto max-w-lg px-4 py-12">
      <h1 className="text-2xl font-semibold">Create the first owner</h1>
      <p className="mt-2 text-sm text-slate-600">This page works once. It needs the server-only bootstrap secret from your environment file.</p>
      <form action={action} className="mt-6 space-y-3 rounded-3xl border bg-white p-6">
        <Field label="Setup secret"><Input name="secret" type="password" required /></Field>
        <Field label="Pharmacy name"><Input name="pharmacy_name" required /></Field>
        <Field label="Owner name"><Input name="owner_name" required /></Field>
        <Field label="Email"><Input name="email" type="email" required /></Field>
        <Field label="Password"><Input name="password" type="password" minLength={8} required /></Field>
        <Field label="State"><Select name="state_code" defaultValue="27">{INDIAN_STATES.map((item) => <option key={item.code} value={item.code}>{item.name}</option>)}</Select></Field>
        <Field label="GSTIN, if registered"><Input name="gstin" /></Field>
        {state && !state.ok ? <p className="text-sm text-rose-700">{state.message}</p> : null}
        {state?.ok ? <p className="text-sm text-emerald-800">Owner created. Sign in from the login page.</p> : null}
        <Button disabled={pending} className="w-full">{pending ? "Creating..." : "Create owner"}</Button>
      </form>
    </main>
  );
}
