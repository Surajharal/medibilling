"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { toast } from "sonner";
import { INDIAN_STATES } from "@/lib/catalog";
import { Button } from "@/components/ui/button";
import { Field, Input, Select } from "@/components/ui/inputs";
import { saveCustomer, saveSupplier } from "@/server/operations";

export function PartyForm({ kind, initial }: { kind: "supplier" | "customer"; initial?: Record<string, string | number | null> }) {
  const router = useRouter();
  const [pending, setPending] = useState(false);
  async function onSubmit(formData: FormData) {
    setPending(true);
    const payload = {
      id: initial?.id || undefined,
      name: formData.get("name"),
      phone: formData.get("phone"),
      email: formData.get("email"),
      address: formData.get("address"),
      state: INDIAN_STATES.find((item) => item.code === formData.get("state_code"))?.name ?? "",
      state_code: formData.get("state_code"),
      gstin: formData.get("gstin"),
      contact_person: formData.get("contact_person"),
      drug_licence: formData.get("drug_licence"),
      payment_terms: formData.get("payment_terms"),
      opening_balance: formData.get("opening_balance") || 0,
      credit_limit: formData.get("credit_limit") || 0,
    };
    const result = kind === "supplier" ? await saveSupplier(payload) : await saveCustomer(payload);
    setPending(false);
    if (!result.ok) toast.error(result.message);
    else {
      toast.success("Saved");
      router.refresh();
    }
  }
  const value = (key: string) => String(initial?.[key] ?? "");
  return (
    <form action={onSubmit} className="grid max-w-3xl gap-3 rounded-2xl border bg-white p-5 md:grid-cols-2">
      <Field label="Name"><Input name="name" required defaultValue={value("name")} /></Field>
      <Field label="Phone"><Input name="phone" defaultValue={value("phone")} /></Field>
      {kind === "supplier" ? <Field label="Email"><Input name="email" defaultValue={value("email")} /></Field> : null}
      {kind === "supplier" ? <Field label="Contact person"><Input name="contact_person" defaultValue={value("contact_person")} /></Field> : null}
      <Field label="Address"><Input name="address" defaultValue={value("address")} /></Field>
      <Field label="State">
        <Select name="state_code" defaultValue={value("state_code") || "27"}>
          {INDIAN_STATES.map((state) => <option key={state.code} value={state.code}>{state.name}</option>)}
        </Select>
      </Field>
      <Field label="GSTIN"><Input name="gstin" defaultValue={value("gstin")} /></Field>
      {kind === "supplier" ? <Field label="Drug licence"><Input name="drug_licence" defaultValue={value("drug_licence")} /></Field> : null}
      {kind === "supplier" ? <Field label="Payment terms"><Input name="payment_terms" defaultValue={value("payment_terms")} /></Field> : null}
      {kind === "customer" ? <Field label="Credit limit"><Input name="credit_limit" defaultValue={value("credit_limit") || "0"} /></Field> : null}
      {!initial?.id ? <Field label="Opening balance"><Input name="opening_balance" defaultValue="0" /></Field> : null}
      <div className="md:col-span-2"><Button disabled={pending}>{pending ? "Saving..." : "Save"}</Button></div>
    </form>
  );
}
