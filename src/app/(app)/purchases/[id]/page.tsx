import { notFound } from "next/navigation";
import { PurchaseReturnForm } from "@/components/purchase-return-form";
import { PageHeader } from "@/components/page-header";
import { formatDateOnly, formatINR, formatQty } from "@/lib/format";
import { requireAction } from "@/lib/tenant";

export default async function PurchaseDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const context = await requireAction("purchases.manage");
  const { data: invoice } = await context.supabase.from("supplier_invoices").select("*, suppliers(name)").eq("id", id).eq("pharmacy_id", context.pharmacy.id).maybeSingle();
  if (!invoice) notFound();
  const { data: items } = await context.supabase.from("purchase_items").select("*").eq("supplier_invoice_id", id);
  return (
    <div>
      <PageHeader title={invoice.supplier_invoice_number} description={`${(invoice.suppliers as { name?: string } | null)?.name ?? ""} · ${formatDateOnly(invoice.invoice_date)} · ${formatINR(invoice.grand_total)}`} />
      <div className="overflow-x-auto rounded-2xl border bg-white">
        <table className="min-w-full text-sm">
          <thead className="bg-slate-50 text-left text-xs uppercase text-slate-500"><tr><th className="px-3 py-2">Medicine</th><th>Batch</th><th>Expiry</th><th>Qty</th><th>Free</th><th>Total</th><th>Returned</th></tr></thead>
          <tbody>
            {(items ?? []).map((item) => (
              <tr key={item.id} className="border-t">
                <td className="px-3 py-2">{item.medicine_name}</td>
                <td>{item.batch_number}</td>
                <td>{formatDateOnly(item.expiry_date)}</td>
                <td>{formatQty(item.qty)}</td>
                <td>{formatQty(item.free_qty)}</td>
                <td>{formatINR(item.line_total)}</td>
                <td>{formatQty(item.returned_qty)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="mt-3 text-sm">Paid {formatINR(invoice.amount_paid)} · Status {invoice.payment_status}</p>
      <PurchaseReturnForm
        invoiceId={id}
        lines={(items ?? []).map((item) => ({
          id: item.id,
          label: `${item.medicine_name} ${item.batch_number}`,
          remaining: Number(item.qty) + Number(item.free_qty) - Number(item.returned_qty),
        }))}
      />
    </div>
  );
}
