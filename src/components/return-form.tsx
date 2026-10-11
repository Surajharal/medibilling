"use client";

import { useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input, Select } from "@/components/ui/inputs";
import { formatINR } from "@/lib/format";
import { postSaleReturn } from "@/server/operations";

export function ReturnForm({ invoiceId, lines }: { invoiceId: string; lines: { id: string; label: string; remaining: number; total: string }[] }) {
  const [qty, setQty] = useState<Record<string, string>>({});
  const [disposition, setDisposition] = useState<Record<string, string>>({});
  const [pending, setPending] = useState(false);

  async function onSubmit(formData: FormData) {
    const selected = lines.filter((line) => Number(qty[line.id]) > 0).map((line) => ({
      invoice_item_id: line.id,
      quantity: qty[line.id],
      disposition: disposition[line.id] || "resale",
    }));
    setPending(true);
    const result = await postSaleReturn({
      idempotency_key: crypto.randomUUID(),
      invoice_id: invoiceId,
      reason: formData.get("reason"),
      balance_credit: formData.get("balance_credit") || "0",
      refunds: Number(formData.get("refund_amount")) > 0 ? [{ method: formData.get("refund_method"), amount: formData.get("refund_amount") }] : [],
      lines: selected,
    });
    setPending(false);
    if (!result.ok) toast.error(result.message);
    else toast.success(`Credit note ${(result.data as { credit_note_number: string }).credit_note_number} posted`);
  }

  return (
    <form action={onSubmit} className="space-y-3">
      {lines.map((line) => (
        <div key={line.id} className="grid gap-2 rounded-xl border bg-white p-3 md:grid-cols-4">
          <div className="text-sm">{line.label}<br />Remaining {line.remaining} · {formatINR(line.total)}</div>
          <Input placeholder="Return qty" value={qty[line.id] ?? ""} onChange={(event) => setQty((current) => ({ ...current, [line.id]: event.target.value }))} />
          <Select value={disposition[line.id] ?? "resale"} onChange={(event) => setDisposition((current) => ({ ...current, [line.id]: event.target.value }))}>
            <option value="resale">Return to saleable stock</option>
            <option value="quarantine">Quarantine</option>
          </Select>
        </div>
      ))}
      <Input name="reason" placeholder="Reason" required minLength={3} />
      <div className="grid gap-2 md:grid-cols-3">
        <Select name="refund_method"><option value="cash">Cash refund</option><option value="upi">UPI refund</option><option value="card">Card refund</option></Select>
        <Input name="refund_amount" placeholder="Refund amount" defaultValue="0" />
        <Input name="balance_credit" placeholder="Reduce customer balance" defaultValue="0" />
      </div>
      <p className="text-xs text-slate-500">Leave both amounts at 0 to refund a paid bill in cash, or to reduce the balance on a credit bill. Expired or blocked stock is quarantined even if saleable is selected.</p>
      <Button disabled={pending}>{pending ? "Posting..." : "Post credit note"}</Button>
    </form>
  );
}
