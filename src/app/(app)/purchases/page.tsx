import Link from "next/link";
import { PurchaseForm } from "@/components/purchase-form";
import { PageHeader, Pager } from "@/components/page-header";
import { formatDateOnly, formatINR } from "@/lib/format";
import { requireAction } from "@/lib/tenant";

export default async function PurchasesPage({ searchParams }: { searchParams: Promise<{ page?: string }> }) {
  const params = await searchParams;
  const context = await requireAction("purchases.manage");
  const page = Math.max(1, Number(params.page ?? 1));
  const from = (page - 1) * 20;
  const { data } = await context.supabase.from("supplier_invoices").select("id, supplier_invoice_number, invoice_date, grand_total, payment_status, suppliers(name)").eq("pharmacy_id", context.pharmacy.id).order("invoice_date", { ascending: false }).range(from, from + 20);
  const rows = data ?? [];
  return (
    <div>
      <PageHeader title="Purchases" action={<Link className="rounded-xl bg-brand-700 px-4 py-3 text-sm font-semibold text-white" href="/purchases/new">New purchase</Link>} />
      <div className="overflow-x-auto rounded-2xl border bg-white">
        <table className="min-w-full text-sm">
          <tbody>
            {rows.slice(0, 20).map((row) => (
              <tr key={row.id} className="border-t">
                <td className="px-3 py-2"><Link className="font-medium text-brand-800" href={`/purchases/${row.id}`}>{row.supplier_invoice_number}</Link></td>
                <td>{(row.suppliers as { name?: string } | null)?.name}</td>
                <td>{formatDateOnly(row.invoice_date)}</td>
                <td>{formatINR(row.grand_total)}</td>
                <td>{row.payment_status}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <Pager page={page} hasMore={rows.length > 20} path="/purchases" query={{}} />
    </div>
  );
}
