import Link from "next/link";
import { PageHeader, Pager } from "@/components/page-header";
import { formatDateOnly, formatINR } from "@/lib/format";
import { safeSearch } from "@/lib/catalog";
import { requireAction } from "@/lib/tenant";

export default async function SalesPage({ searchParams }: { searchParams: Promise<{ q?: string; page?: string }> }) {
  const params = await searchParams;
  const context = await requireAction("sales.view");
  const page = Math.max(1, Number(params.page ?? 1));
  const q = safeSearch(params.q ?? "");
  const from = (page - 1) * 20;
  let query = context.supabase.from("sales_invoices").select("id, invoice_number, business_date, customer_name_snapshot, grand_total, payment_status, return_status, created_at", { count: "exact" }).eq("pharmacy_id", context.pharmacy.id).order("created_at", { ascending: false }).range(from, from + 20);
  if (q) query = query.ilike("invoice_number", `%${q}%`);
  const { data } = await query;
  const rows = data ?? [];
  return (
    <div>
      <PageHeader title="Sales history" description="Posted invoices stay as they were created. Returns are separate credit notes." />
      <form className="mb-4"><input name="q" defaultValue={q} placeholder="Invoice number" className="h-11 w-full max-w-sm rounded-xl border px-3" /></form>
      <div className="overflow-x-auto rounded-2xl border bg-white">
        <table className="min-w-full text-sm">
          <thead className="bg-slate-50 text-left text-xs uppercase text-slate-500"><tr><th className="px-3 py-2">Invoice</th><th>Date</th><th>Customer</th><th>Total</th><th>Payment</th><th>Return</th></tr></thead>
          <tbody>
            {rows.slice(0, 20).map((row) => (
              <tr key={row.id} className="border-t">
                <td className="px-3 py-2"><Link className="font-medium text-brand-800" href={`/sales/${row.id}`}>{row.invoice_number}</Link></td>
                <td>{formatDateOnly(row.business_date)}</td>
                <td>{row.customer_name_snapshot}</td>
                <td>{formatINR(row.grand_total)}</td>
                <td>{row.payment_status}</td>
                <td>{row.return_status}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <Pager page={page} hasMore={rows.length > 20} path="/sales" query={{ q }} />
    </div>
  );
}
