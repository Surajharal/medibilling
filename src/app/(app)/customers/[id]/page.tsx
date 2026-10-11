import { notFound, redirect } from "next/navigation";
import { PageHeader } from "@/components/page-header";
import { formatDateOnly, formatINR } from "@/lib/format";
import { requireAction } from "@/lib/tenant";
import { recordCustomerReceipt } from "@/server/operations";

export default async function CustomerPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ error?: string; saved?: string }> }) {
  const { id } = await params;
  const query = await searchParams;
  const context = await requireAction("customers.view");
  const { data: customer } = await context.supabase.from("customers").select("*").eq("id", id).eq("pharmacy_id", context.pharmacy.id).maybeSingle();
  if (!customer) notFound();
  const { data: invoices } = await context.supabase.from("sales_invoices").select("id, invoice_number, business_date, grand_total").eq("customer_id", id).order("created_at", { ascending: false }).limit(30);
  async function receive(formData: FormData) {
    "use server";
    const result = await recordCustomerReceipt({ customer_id: id, amount: formData.get("amount"), method: formData.get("method") });
    if (!result.ok) redirect(`/customers/${id}?error=${encodeURIComponent(result.message)}`);
    redirect(`/customers/${id}?saved=1`);
  }
  return (
    <div>
      <PageHeader title={customer.name} description={`Outstanding ${formatINR(customer.outstanding_balance)} · limit ${formatINR(customer.credit_limit)}`} />
      {query.error ? <p className="mb-3 text-sm text-rose-700">{query.error}</p> : null}
      {query.saved ? <p className="mb-3 text-sm text-emerald-700">Receipt recorded.</p> : null}
      <form action={receive} className="flex max-w-md gap-2">
        <input name="amount" placeholder="Receipt amount" className="h-11 flex-1 rounded-xl border px-3" />
        <select name="method" className="h-11 rounded-xl border px-3"><option value="cash">Cash</option><option value="upi">UPI</option></select>
        <button className="rounded-xl bg-brand-700 px-4 text-sm font-semibold text-white">Receive</button>
      </form>
      <ul className="mt-6 space-y-2 text-sm">
        {(invoices ?? []).map((invoice) => <li key={invoice.id}><a className="text-brand-800" href={`/sales/${invoice.id}`}>{invoice.invoice_number}</a> · {formatDateOnly(invoice.business_date)} · {formatINR(invoice.grand_total)}</li>)}
      </ul>
    </div>
  );
}
