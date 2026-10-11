import Link from "next/link";
import { PageHeader } from "@/components/page-header";
import { formatDateOnly, formatINR, formatQty } from "@/lib/format";
import { mapDbError } from "@/lib/errors";
import { can } from "@/lib/permissions";
import { requireAction } from "@/lib/tenant";

const VIEWS = [
  { id: "saleable", label: "Saleable" },
  { id: "low", label: "Low stock" },
  { id: "out", label: "Out of stock" },
  { id: "expired", label: "Expired" },
  { id: "30", label: "30 days" },
  { id: "60", label: "60 days" },
  { id: "90", label: "90 days" },
  { id: "blocked", label: "Blocked" },
];

export default async function InventoryPage({ searchParams }: { searchParams: Promise<{ view?: string }> }) {
  const params = await searchParams;
  const view = params.view || "saleable";
  const context = await requireAction("inventory.view");
  const { data, error } = await context.supabase.rpc("report_query", {
    p_pharmacy: context.pharmacy.id,
    p_report: view === "low" || view === "out" ? "low_stock" : view === "saleable" ? "stock_valuation" : "expiry",
    p_extra: { window: view === "blocked" ? "quarantine" : view },
  });
  const report = (data ?? { rows: [], title: "Inventory" }) as { rows: Record<string, string>[]; title?: string; note?: string };
  if (context.role === "billing_operator" && error) {
    const { data: batches } = await context.supabase.from("inventory_batches").select("id, batch_number, expiry_date, qty_available, mrp, status, medicines(name)").eq("pharmacy_id", context.pharmacy.id).limit(100);
    return (
      <div>
        <PageHeader title="Inventory" />
        <ul className="space-y-2 text-sm">{(batches ?? []).map((batch) => <li key={batch.id}>{String((batch.medicines as { name?: string } | null)?.name ?? "")} · {batch.batch_number} · {formatQty(batch.qty_available)}</li>)}</ul>
      </div>
    );
  }
  return (
    <div>
      <PageHeader title="Inventory" description="Stock stays attached to its batch. One expired batch does not expire the whole medicine." action={can(context.role, "inventory.adjust") ? <Link className="rounded-xl bg-brand-700 px-4 py-3 text-sm font-semibold text-white" href="/inventory/adjust">Adjust stock</Link> : null} />
      <div className="mb-4 flex flex-wrap gap-2">
        {VIEWS.map((item) => <Link key={item.id} href={`/inventory?view=${item.id}`} className={`rounded-full px-3 py-1 text-sm ${view === item.id ? "bg-brand-700 text-white" : "bg-white border"}`}>{item.label}</Link>)}
      </div>
      {report.note ? <p className="mb-3 text-xs text-slate-500">{report.note}</p> : null}
      {error ? <p className="mb-3 text-sm text-rose-700">{mapDbError(error)}</p> : null}
      <div className="overflow-x-auto rounded-2xl border bg-white">
        <table className="min-w-full text-sm">
          <tbody>
            {(report.rows ?? []).map((row, index) => (
              <tr key={index} className="border-t">
                {Object.entries(row).map(([key, value]) => <td key={key} className="px-3 py-2">{key.includes("value") || key === "mrp" ? formatINR(value) : key.includes("expiry") || key === "date" ? formatDateOnly(String(value)) : String(value)}</td>)}
              </tr>
            ))}
            {(report.rows ?? []).length === 0 ? <tr><td className="px-3 py-8 text-slate-500">No rows in this view.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}
