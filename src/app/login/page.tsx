"use client";

import { useActionState } from "react";
import { login } from "@/server/auth";
import { Button } from "@/components/ui/button";
import { Field, Input } from "@/components/ui/inputs";

export default function LoginPage() {
  const [state, action, pending] = useActionState(async (_prev: { message?: string } | null, formData: FormData) => login(formData), null);
  return (
    <main className="grid min-h-screen place-items-center px-4">
      <form action={action} className="w-full max-w-md rounded-3xl border border-slate-200 bg-white p-8 shadow-sm">
        <p className="text-sm font-semibold text-brand-700">MediBilling</p>
        <h1 className="mt-2 text-2xl font-semibold">Sign in to the counter</h1>
        <p className="mt-2 text-sm text-slate-600">Use the account created by the store owner.</p>
        <div className="mt-6 space-y-4">
          <Field label="Email"><Input name="email" type="email" autoComplete="username" required /></Field>
          <Field label="Password"><Input name="password" type="password" autoComplete="current-password" required /></Field>
        </div>
        {state?.message ? <p className="mt-4 text-sm text-rose-700">{state.message}</p> : null}
        <Button className="mt-6 w-full" size="lg" disabled={pending}>{pending ? "Signing in..." : "Sign in"}</Button>
        <a className="mt-4 block text-center text-sm text-brand-800" href="/forgot-password">Forgot password</a>
      </form>
    </main>
  );
}
