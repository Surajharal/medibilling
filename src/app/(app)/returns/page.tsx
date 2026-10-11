import { ReturnForm } from "@/components/return-form";
import { PageHeader } from "@/components/page-header";
import { formatDateOnly, formatINR } from "@/lib/format";
import { requireAction } from "@/lib/tenant";

export default async function ReturnsPage({ searchParams }: { searchParams: Promise<{ invoice?: string }> }) {
  const params = await searchParams;
  const context = await requireAction("returns.manage");
  const { data: recent } = await context.supabase.from("sales_returns").select("id, credit_note_number, business_date, grand_total, reason").eq("pharmacy_id", context.pharmacy.id).order("created_at", { ascending: false }).limit(20);
  const lookup = params.invoice?.trim() ?? "";
  let invoiceId = lookup;
  let missingInvoice = false;
  if (lookup) {
    const { data: byNumber } = await context.supabase.from("sales_invoices").select("id").eq("pharmacy_id", context.pharmacy.id).ilike("invoice_number", lookup).maybeSingle();
    if (byNumber?.id) invoiceId = byNumber.id;
    else if (!/^[0-9a-f-]{36}$/i.test(lookup)) missingInvoice = true;
  }
  let form = null;
  if (invoiceId && !missingInvoice) {
    const { data: items } = await context.supabase.from("sales_invoice_items").select("id, medicine_name, strength, quantity, returned_qty, line_total").eq("invoice_id", invoiceId).eq("pharmacy_id", context.pharmacy.id);
    if (!items?.length) missingInvoice = true;
    else form = (
      <ReturnForm
        invoiceId={invoiceId}
        lines={items.map((item) => ({
          id: item.id,
          label: `${item.medicine_name} ${item.strength}`,
          remaining: Number(item.quantity) - Number(item.returned_qty),
          total: String(item.line_total),
        }))}
      />
    );
  }
  return (
    <div className="space-y-6">
      <PageHeader title="Returns" description="Posted bills are not edited. A return creates a credit note and restores only eligible stock." />
      <form className="flex gap-2">
        <input name="invoice" defaultValue={params.invoice} placeholder="Invoice number" className="h-11 flex-1 rounded-xl border px-3" />
        <button className="rounded-xl border bg-white px-4 text-sm">Open invoice</button>
      </form>
      {missingInvoice ? <p className="text-sm text-rose-700">No bill was found with that invoice number. Open the bill from Sales and use Return items from this bill.</p> : null}
      {form}
      <ul className="space-y-2 text-sm">
        {(recent ?? []).map((row) => <li key={row.id}>{row.credit_note_number} · {formatDateOnly(row.business_date)} · {formatINR(row.grand_total)} · {row.reason}</li>)}
      </ul>
    </div>
  );
}
