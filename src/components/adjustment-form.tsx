"use client";

import { useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Field, Input, Select, Textarea } from "@/components/ui/inputs";
import { adjustStock } from "@/server/operations";

export function AdjustmentForm({ batches }: { batches: { id: string; label: string }[] }) {
  const [pending, setPending] = useState(false);
  async function onSubmit(formData: FormData) {
    setPending(true);
    const result = await adjustStock({
      batch_id: formData.get("batch_id"),
      adjustment_type: formData.get("adjustment_type"),
      quantity_delta: formData.get("quantity_delta"),
      reason: formData.get("reason"),
    });
    setPending(false);
    if (!result.ok) toast.error(result.message);
    else toast.success("Stock adjustment posted");
  }
  return (
    <form action={onSubmit} className="max-w-xl space-y-4 rounded-2xl border bg-white p-5">
      <Field label="Batch"><Select name="batch_id">{batches.map((batch) => <option key={batch.id} value={batch.id}>{batch.label}</option>)}</Select></Field>
      <Field label="Type">
        <Select name="adjustment_type">
          <option value="correction">Correction</option>
          <option value="write_off">Write off</option>
          <option value="damage">Damage</option>
          <option value="quarantine">Quarantine</option>
          <option value="recall">Recall</option>
        </Select>
      </Field>
      <Field label="Quantity change" hint="Use a negative number to remove stock. Write-off, damage, quarantine, and recall must be negative."><Input name="quantity_delta" required /></Field>
      <Field label="Reason"><Textarea name="reason" required minLength={5} /></Field>
      <Button disabled={pending}>{pending ? "Posting..." : "Post adjustment"}</Button>
    </form>
  );
}
