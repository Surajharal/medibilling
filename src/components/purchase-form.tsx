"use client";

import { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Field, Input, Select } from "@/components/ui/inputs";
import { postPurchase } from "@/server/operations";

type Medicine = { id: string; name: string; strength: string; gst_rate: number };
type Line = { medicine_id: string; batch_number: string; expiry_date: string; qty: string; free_qty: string; purchase_rate: string; mrp: string; selling_price: string; discount_percent: string; gst_rate: string; pack_to_unit: string; shelf: string };

const empty = (medicineId: string, gst: string): Line => ({
  medicine_id: medicineId, batch_number: "", expiry_date: "", qty: "1", free_qty: "0",
  purchase_rate: "", mrp: "", selling_price: "", discount_percent: "0", gst_rate: gst, pack_to_unit: "1", shelf: "",
});

export function PurchaseForm({ suppliers, medicines }: { suppliers: { id: string; name: string }[]; medicines: Medicine[] }) {
  const router = useRouter();
  const [lines, setLines] = useState<Line[]>([empty(medicines[0]?.id ?? "", String(medicines[0]?.gst_rate ?? 0))]);
  const [pending, setPending] = useState(false);

  async function onSubmit(formData: FormData) {
    const problem = lines.find((line) => !line.batch_number.trim() || !line.expiry_date || Number(line.purchase_rate) < 0 || line.purchase_rate === "" || line.mrp === "" || line.selling_price === "" || Number(line.selling_price) > Number(line.mrp));
    if (problem) {
      toast.error(!problem.batch_number.trim() ? "Enter a batch number." : !problem.expiry_date ? "Enter the batch expiry date." : Number(problem.selling_price) > Number(problem.mrp) ? "The selling price cannot be above MRP." : "Enter the rate, MRP, and selling price.");
      return;
    }
    const total = lines.reduce((sum, line) => {
      const taxable = Number(line.qty) * Number(line.purchase_rate) * (1 - Number(line.discount_percent || 0) / 100);
      return sum + taxable + taxable * Number(line.gst_rate || 0) / 100;
    }, 0);
    const paid = Number(formData.get("amount_paid") || 0);
    if (paid > total + 0.05) {
      toast.error(`Amount paid is ₹${paid.toFixed(2)}, which is more than the purchase total of about ₹${total.toFixed(2)}. The rate is before GST.`);
      return;
    }
    setPending(true);
    const result = await postPurchase({
      idempotency_key: crypto.randomUUID(),
      supplier_id: formData.get("supplier_id"),
      supplier_invoice_number: formData.get("supplier_invoice_number"),
      invoice_date: formData.get("invoice_date"),
      amount_paid: formData.get("amount_paid") || "0",
      override_duplicate: formData.get("override_duplicate") === "on",
      notes: formData.get("notes") || "",
      lines,
    });
    setPending(false);
    if (!result.ok) {
      toast.error(result.message);
      return;
    }
    const data = result.data as { invoice_id: string };
    toast.success("Purchase posted");
    router.push(`/purchases/${data.invoice_id}`);
  }

  return (
    <form action={onSubmit} className="space-y-4">
      <div className="grid gap-3 rounded-2xl border bg-white p-4 md:grid-cols-2">
        <Field label="Supplier"><Select name="supplier_id">{suppliers.map((supplier) => <option key={supplier.id} value={supplier.id}>{supplier.name}</option>)}</Select></Field>
        <Field label="Supplier invoice number"><Input name="supplier_invoice_number" required /></Field>
        <Field label="Invoice date"><Input name="invoice_date" type="date" required /></Field>
        <Field label="Amount paid now"><Input name="amount_paid" defaultValue="0" /></Field>
        <label className="flex items-center gap-2 text-sm md:col-span-2"><input type="checkbox" name="override_duplicate" /> Owner override for a duplicate supplier invoice number</label>
      </div>
      {lines.map((line, index) => (
        <div key={index} className="grid gap-2 rounded-2xl border bg-white p-4 md:grid-cols-4">
          <Field label="Medicine">
            <Select value={line.medicine_id} onChange={(event) => {
              const medicine = medicines.find((item) => item.id === event.target.value);
              setLines((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, medicine_id: event.target.value, gst_rate: String(medicine?.gst_rate ?? item.gst_rate) } : item));
            }}>
              {medicines.map((medicine) => <option key={medicine.id} value={medicine.id}>{medicine.name} {medicine.strength}</option>)}
            </Select>
          </Field>
          <p className="text-xs text-slate-500 md:col-span-4">This list is medicines already saved. To buy a new medicine, <Link className="font-semibold text-brand-800" href="/medicines/new">add it on the Medicines page</Link>, then come back and fill the batch, expiry, quantity, rate, MRP, and selling price below.</p>
          <Field label="Batch"><Input value={line.batch_number} onChange={(event) => setLines((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, batch_number: event.target.value } : item))} /></Field>
          <Field label="Expiry"><Input type="date" value={line.expiry_date} onChange={(event) => setLines((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, expiry_date: event.target.value } : item))} /></Field>
          <Field label="Paid qty"><Input value={line.qty} onChange={(event) => setLines((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, qty: event.target.value } : item))} /></Field>
          <Field label="Free qty"><Input value={line.free_qty} onChange={(event) => setLines((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, free_qty: event.target.value } : item))} /></Field>
          <Field label="Rate"><Input value={line.purchase_rate} onChange={(event) => setLines((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, purchase_rate: event.target.value } : item))} /></Field>
          <Field label="MRP"><Input value={line.mrp} onChange={(event) => setLines((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, mrp: event.target.value } : item))} /></Field>
          <Field label="Selling price"><Input value={line.selling_price} onChange={(event) => setLines((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, selling_price: event.target.value } : item))} /></Field>
          <Field label="Discount %"><Input value={line.discount_percent} onChange={(event) => setLines((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, discount_percent: event.target.value } : item))} /></Field>
          <Field label="GST %"><Input value={line.gst_rate} onChange={(event) => setLines((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, gst_rate: event.target.value } : item))} /></Field>
          <Field label="Shelf"><Input value={line.shelf} onChange={(event) => setLines((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, shelf: event.target.value } : item))} /></Field>
        </div>
      ))}
      <div className="flex gap-2">
        <Button type="button" variant="secondary" onClick={() => setLines((current) => [...current, empty(medicines[0]?.id ?? "", String(medicines[0]?.gst_rate ?? 0))])}>Add line</Button>
        <Button disabled={pending}>{pending ? "Posting..." : "Post purchase"}</Button>
      </div>
    </form>
  );
}
