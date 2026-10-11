import Link from "next/link";
import { notFound } from "next/navigation";
import { PageHeader } from "@/components/page-header";
import { formatDateOnly, formatINR, formatQty } from "@/lib/format";
import { can } from "@/lib/permissions";
import { requireAction } from "@/lib/tenant";

export default async function SaleDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const context = await requireAction("sales.view");
  const { data: invoice } = await context.supabase.from("sales_invoices").select("*").eq("id", id).eq("pharmacy_id", context.pharmacy.id).maybeSingle();
  if (!invoice) notFound();
  const { data: items } = await context.supabase.from("sales_invoice_items").select("*").eq("invoice_id", id).order("line_no");
  const { data: payments } = await context.supabase.from("sales_payments").select("*").eq("invoice_id", id);
  return (
    <div>
      <PageHeader title={invoice.invoice_number} description={`${invoice.invoice_kind === "tax_invoice" ? "Tax invoice" : "Retail bill"} · ${formatDateOnly(invoice.business_date)} · ${invoice.customer_name_snapshot}`} action={<Link className="rounded-xl bg-brand-700 px-4 py-3 text-sm font-semibold text-white" href={`/sales/${id}/print`}>Print</Link>} />
      <div className="overflow-x-auto rounded-2xl border bg-white">
        <table className="min-w-full text-sm">
          <thead className="bg-slate-50 text-left text-xs uppercase text-slate-500"><tr><th className="px-3 py-2">Medicine</th><th>Batch</th><th>Expiry</th><th>Qty</th><th>Taxable</th><th>GST</th><th>Total</th><th>Returned</th></tr></thead>
          <tbody>
            {(items ?? []).map((item) => (
              <tr key={item.id} className="border-t">
                <td className="px-3 py-2">{item.medicine_name} {item.strength} {item.dosage_form}</td>
                <td>{item.batch_number}</td>
                <td>{formatDateOnly(item.expiry_date)}</td>
                <td>{formatQty(item.quantity)} {item.sold_unit}</td>
                <td>{formatINR(item.taxable_value)}</td>
                <td>{formatINR(Number(item.cgst) + Number(item.sgst) + Number(item.igst))}</td>
                <td>{formatINR(item.line_total)}</td>
                <td>{formatQty(item.returned_qty)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="mt-4 grid gap-2 text-sm sm:grid-cols-2">
        <p>Taxable {formatINR(invoice.taxable_value)} · CGST {formatINR(invoice.cgst)} · SGST {formatINR(invoice.sgst)} · IGST {formatINR(invoice.igst)}</p>
        <p className="font-semibold">Total {formatINR(invoice.grand_total)} · Paid {formatINR(invoice.amount_paid)} · Due {formatINR(invoice.balance_due)}</p>
        <p>Payments: {(payments ?? []).map((payment) => `${payment.method} ${formatINR(payment.amount)}`).join(", ") || "None"}</p>
        {Number(invoice.change_due) > 0 ? <p>Change {formatINR(invoice.change_due)}</p> : null}
      </div>
      {can(context.role, "returns.manage") ? <Link className="mt-4 inline-block text-sm font-semibold text-brand-800" href={`/returns?invoice=${id}`}>Return items from this bill</Link> : null}
    </div>
  );
}
