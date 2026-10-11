"use client";

import { useActionState } from "react";
import { requestPasswordReset } from "@/server/auth";
import { Button } from "@/components/ui/button";
import { Field, Input } from "@/components/ui/inputs";

export default function ForgotPasswordPage() {
  const [state, action, pending] = useActionState(async (_prev: { message?: string } | null, formData: FormData) => requestPasswordReset(formData), null);
  return (
    <main className="grid min-h-screen place-items-center px-4">
      <form action={action} className="w-full max-w-md rounded-3xl border bg-white p-8">
        <h1 className="text-2xl font-semibold">Reset password</h1>
        <Field label="Email"><Input name="email" type="email" required /></Field>
        {state?.message ? <p className="mt-4 text-sm text-slate-700">{state.message}</p> : null}
        <Button className="mt-6 w-full" disabled={pending}>Send reset link</Button>
        <a className="mt-4 block text-center text-sm" href="/login">Back to sign in</a>
      </form>
    </main>
  );
}
