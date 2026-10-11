import { notFound } from "next/navigation";
import { PrintButton } from "@/components/print-button";
import { formatDateOnly, formatDateTime, formatINR, formatQty } from "@/lib/format";
import { getSessionContext } from "@/lib/tenant";

export default async function PrintInvoicePage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ format?: string }> }) {
  const { id } = await params;
  const query = await searchParams;
  const thermal = query.format !== "a4";
  const context = await getSessionContext();
  const { data: invoice } = await context.supabase.from("sales_invoices").select("*").eq("id", id).eq("pharmacy_id", context.pharmacy.id).maybeSingle();
  if (!invoice) notFound();
  const { data: items } = await context.supabase.from("sales_invoice_items").select("*").eq("invoice_id", id).order("line_no");
  const { data: payments } = await context.supabase.from("sales_payments").select("*").eq("invoice_id", id);
  const title = invoice.invoice_kind === "tax_invoice" ? "Tax invoice" : "Retail bill";
  return (
    <main className={thermal ? "mx-auto w-[80mm] bg-white p-3 text-[12px]" : "mx-auto max-w-3xl bg-white p-8"}>
      <div className="no-print mb-4 flex gap-2">
        <PrintButton />
        <a className="rounded-lg border px-3 py-2 text-sm" href={`/sales/${id}/print?format=${thermal ? "a4" : "thermal"}`}>{thermal ? "A4 layout" : "Thermal layout"}</a>
        <a className="rounded-lg border px-3 py-2 text-sm" href={`/sales/${id}`}>Back</a>
      </div>
      {invoice.logo_url ? <img src={invoice.logo_url} alt={invoice.seller_name} className="mb-2 h-12 object-contain" /> : null}
      <h1 className="text-center text-lg font-bold">{invoice.seller_name}</h1>
      <p className="text-center">{invoice.seller_address}</p>
      <p className="text-center">{invoice.seller_phone}</p>
      {invoice.seller_gstin ? <p className="text-center">GSTIN {invoice.seller_gstin}</p> : null}
      {invoice.seller_drug_licences ? <p className="text-center">DL {invoice.seller_drug_licences}</p> : null}
      <p className="mt-3 text-center font-semibold uppercase">{title}</p>
      {invoice.invoice_kind !== "tax_invoice" ? <p className="text-center text-[11px]">This retail bill is not a GST tax invoice.</p> : null}
      <p className="mt-2">No. {invoice.invoice_number}</p>
      <p>Date {formatDateTime(invoice.created_at, context.pharmacy.timezone)}</p>
      <p>Customer {invoice.customer_name_snapshot}</p>
      {invoice.customer_gstin_snapshot ? <p>Customer GSTIN {invoice.customer_gstin_snapshot}</p> : null}
      <p>Place of supply {invoice.place_of_supply_code} · {invoice.supply_type === "inter" ? "IGST" : "CGST + SGST"} · {invoice.pricing_mode} prices</p>
      <table className="mt-3 w-full">
        <thead><tr className="border-y text-left"><th>Item</th><th>Qty</th><th>Amount</th></tr></thead>
        <tbody>
          {(items ?? []).map((item) => (
            <tr key={item.id} className="align-top">
              <td className="py-1">{item.medicine_name} {item.strength} {item.dosage_form}<br />Batch {item.batch_number} exp {formatDateOnly(item.expiry_date)}{item.hsn_code ? ` · HSN ${item.hsn_code}` : ""}</td>
              <td>{formatQty(item.quantity)}</td>
              <td>{formatINR(item.line_total)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <div className="mt-3 space-y-1 border-t pt-2">
        <p>Taxable {formatINR(invoice.taxable_value)}</p>
        <p>CGST {formatINR(invoice.cgst)} · SGST {formatINR(invoice.sgst)} · IGST {formatINR(invoice.igst)}</p>
        <p>Discount {formatINR(invoice.discount_amount)} · Round off {formatINR(invoice.round_off)}</p>
        <p className="text-base font-bold">Total {formatINR(invoice.grand_total)}</p>
        <p>Paid {formatINR(invoice.amount_paid)} · Due {formatINR(invoice.balance_due)}</p>
        {(payments ?? []).map((payment) => <p key={payment.id}>{payment.method}: {formatINR(payment.amount)}</p>)}
        {Number(invoice.change_due) > 0 ? <p>Change {formatINR(invoice.change_due)}</p> : null}
      </div>
      <p className="mt-4 text-center">{invoice.footer_snapshot || "Goods once sold as per the store policy."}</p>
      <p className="mt-6 text-center">Authorised signatory</p>
    </main>
  );
}
