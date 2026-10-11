import Link from "next/link";
import { SalesTrend } from "@/components/sales-trend";
import { PageHeader } from "@/components/page-header";
import { Card } from "@/components/ui/card";
import { formatDateOnly, formatINR, formatQty, todayInTimeZone } from "@/lib/format";
import { requireAction } from "@/lib/tenant";

function Metric({ label, value, tone = "text-ink" }: { label: string; value: string; tone?: string }) {
  return (
    <Card>
      <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">{label}</p>
      <p className={`mt-2 text-2xl font-semibold ${tone}`}>{value}</p>
    </Card>
  );
}

export default async function DashboardPage({ searchParams }: { searchParams: Promise<{ from?: string; to?: string; group?: string }> }) {
  const params = await searchParams;
  const context = await requireAction("dashboard.view");
  const today = todayInTimeZone(context.pharmacy.timezone);
  const from = params.from || today;
  const to = params.to || today;
  const group = params.group || "day";
  const { data, error } = await context.supabase.rpc("dashboard_summary", {
    p_pharmacy: context.pharmacy.id,
    p_from: from,
    p_to: to,
    p_group: group,
  });
  if (error || !data) {
    return <p className="text-sm text-rose-700">The dashboard could not be loaded. Apply the database migrations and sign in again.</p>;
  }
  const summary = data as Record<string, unknown> & {
    recent_invoices: { id: string; invoice_number: string; business_date: string; customer_name: string; grand_total: string }[];
    recent_purchases: { id: string; supplier_invoice_number: string; invoice_date: string; supplier_name: string; grand_total: string }[];
    top_medicines: { name: string; quantity: string; amount: string }[];
    trend: { period: string; total: string }[];
  };

  return (
    <div>
      <PageHeader title="Dashboard" description="Figures come from posted invoices, purchases, and batch stock." />
      <form className="mb-4 flex flex-wrap gap-2" action="/dashboard">
        <input className="h-11 rounded-xl border px-3" type="date" name="from" defaultValue={from} />
        <input className="h-11 rounded-xl border px-3" type="date" name="to" defaultValue={to} />
        <select className="h-11 rounded-xl border px-3" name="group" defaultValue={group}>
          <option value="day">By day</option>
          <option value="week">By week</option>
          <option value="month">By month</option>
        </select>
        <button className="h-11 rounded-xl bg-brand-700 px-4 text-sm font-semibold text-white">Apply</button>
      </form>
      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <Metric label="Sales" value={formatINR(String(summary.sales_total))} />
        <Metric label="Invoices" value={String(summary.invoice_count)} />
        <Metric label="Net sales" value={formatINR(String(summary.net_sales))} />
        <Metric label="Discounts" value={formatINR(String(summary.discounts))} />
        <Metric label="Cash" value={formatINR(String(summary.cash))} />
        <Metric label="UPI" value={formatINR(String(summary.upi))} />
        <Metric label="Card" value={formatINR(String(summary.card))} />
        <Metric label="Bank transfer" value={formatINR(String(summary.bank_transfer))} />
        <Metric label="Credit" value={formatINR(String(summary.credit))} />
        <Metric label="Returns" value={formatINR(String(summary.returns_total))} tone="text-warning" />
        {summary.gross_profit ? <Metric label="Estimated gross profit" value={formatINR(String(summary.gross_profit))} /> : null}
        <Metric label="Saleable stock at cost" value={formatINR(String(summary.inventory_cost))} />
        <Metric label="Medicines" value={String(summary.medicine_count)} />
        <Metric label="Active batches" value={String(summary.active_batch_count)} />
        <Metric label="Low stock medicines" value={String(summary.low_stock_count)} tone="text-warning" />
        <Metric label="Expiring in 30 days" value={String(summary.expiring_30)} tone="text-warning" />
        <Metric label="Expiring in 60 days" value={String(summary.expiring_60)} tone="text-warning" />
        <Metric label="Expiring in 90 days" value={String(summary.expiring_90)} tone="text-warning" />
        <Metric label="Expired quantity" value={formatQty(String(summary.expired_qty))} tone="text-danger" />
        <Metric label="Expired value" value={formatINR(String(summary.expired_value))} tone="text-danger" />
        <Metric label="Supplier dues" value={formatINR(String(summary.supplier_outstanding))} />
      </div>
      <p className="mt-4 text-xs text-slate-500">{String(summary.gross_profit_note ?? "")}</p>
      <div className="mt-6 grid gap-4 lg:grid-cols-2">
        <Card>
          <h2 className="mb-3 font-semibold">Sales trend</h2>
          <SalesTrend points={summary.trend ?? []} />
        </Card>
        <Card>
          <h2 className="mb-3 font-semibold">Top medicines</h2>
          <ul className="space-y-2 text-sm">
            {(summary.top_medicines ?? []).map((item) => (
              <li key={item.name} className="flex justify-between gap-3"><span>{item.name}</span><span>{formatQty(item.quantity)} · {formatINR(item.amount)}</span></li>
            ))}
            {(summary.top_medicines ?? []).length === 0 ? <li className="text-slate-500">No sales in this range.</li> : null}
          </ul>
        </Card>
        <Card>
          <h2 className="mb-3 font-semibold">Recent invoices</h2>
          <ul className="space-y-2 text-sm">
            {(summary.recent_invoices ?? []).map((invoice) => (
              <li key={invoice.id}><Link className="font-medium text-brand-800" href={`/sales/${invoice.id}`}>{invoice.invoice_number}</Link> · {formatDateOnly(invoice.business_date)} · {invoice.customer_name} · {formatINR(invoice.grand_total)}</li>
            ))}
          </ul>
        </Card>
        <Card>
          <h2 className="mb-3 font-semibold">Recent purchases</h2>
          <ul className="space-y-2 text-sm">
            {(summary.recent_purchases ?? []).map((purchase) => (
              <li key={purchase.id}><Link className="font-medium text-brand-800" href={`/purchases/${purchase.id}`}>{purchase.supplier_invoice_number}</Link> · {formatDateOnly(purchase.invoice_date)} · {purchase.supplier_name} · {formatINR(purchase.grand_total)}</li>
            ))}
          </ul>
        </Card>
      </div>
    </div>
  );
}
