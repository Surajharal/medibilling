"use client";

import { useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/inputs";
import { postPurchaseReturn } from "@/server/operations";

export function PurchaseReturnForm({ invoiceId, lines }: { invoiceId: string; lines: { id: string; label: string; remaining: number }[] }) {
  const [qty, setQty] = useState<Record<string, string>>({});
  const [pending, setPending] = useState(false);

  async function onSubmit(formData: FormData) {
    const selected = lines.filter((line) => Number(qty[line.id]) > 0).map((line) => ({
      purchase_item_id: line.id,
      quantity: qty[line.id],
    }));
    setPending(true);
    const result = await postPurchaseReturn({
      idempotency_key: crypto.randomUUID(),
      supplier_invoice_id: invoiceId,
      reason: formData.get("reason"),
      lines: selected,
    });
    setPending(false);
    if (!result.ok) toast.error(result.message);
    else toast.success("Debit note posted");
  }

  return (
    <form action={onSubmit} className="mt-6 space-y-3">
      <h2 className="font-semibold">Supplier return</h2>
      {lines.map((line) => (
        <div key={line.id} className="grid items-center gap-2 md:grid-cols-2">
          <span className="text-sm">{line.label} · remaining {line.remaining}</span>
          <Input placeholder="Return qty" value={qty[line.id] ?? ""} onChange={(event) => setQty((current) => ({ ...current, [line.id]: event.target.value }))} />
        </div>
      ))}
      <Input name="reason" placeholder="Reason" required minLength={3} />
      <Button disabled={pending}>{pending ? "Posting..." : "Post debit note"}</Button>
    </form>
  );
}
