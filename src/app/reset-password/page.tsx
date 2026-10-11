"use client";

import { useActionState } from "react";
import { updatePassword } from "@/server/auth";
import { Button } from "@/components/ui/button";
import { Field, Input } from "@/components/ui/inputs";

export default function ResetPasswordPage() {
  const [state, action, pending] = useActionState(async (_prev: { message?: string } | null, formData: FormData) => updatePassword(formData), null);
  return (
    <main className="grid min-h-screen place-items-center px-4">
      <form action={action} className="w-full max-w-md rounded-3xl border bg-white p-8">
        <h1 className="text-2xl font-semibold">Choose a new password</h1>
        <Field label="New password"><Input name="password" type="password" minLength={8} required /></Field>
        {state?.message ? <p className="mt-4 text-sm text-rose-700">{state.message}</p> : null}
        <Button className="mt-6 w-full" disabled={pending}>Update password</Button>
      </form>
    </main>
  );
}
