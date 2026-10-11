import { notFound } from "next/navigation";
import { PageHeader } from "@/components/page-header";
import { formatINR } from "@/lib/format";
import { mapDbError } from "@/lib/errors";
import { todayInTimeZone } from "@/lib/format";
import { requireAction } from "@/lib/tenant";

export default async function ReportPage({ params, searchParams }: { params: Promise<{ slug: string }>; searchParams: Promise<{ from?: string; to?: string; window?: string; group?: string }> }) {
  const { slug } = await params;
  const query = await searchParams;
  const context = await requireAction(slug === "gross_profit" ? "reports.profit" : "reports.view");
  const today = todayInTimeZone(context.pharmacy.timezone);
  const { data, error } = await context.supabase.rpc("report_query", {
    p_pharmacy: context.pharmacy.id,
    p_report: slug,
    p_from: query.from || today,
    p_to: query.to || today,
    p_extra: { window: query.window || "30", group: query.group || "week" },
  });
  if (error) return <p className="text-sm text-rose-700">{mapDbError(error)}</p>;
  if (!data) notFound();
  const report = data as { title: string; note: string; rows: Record<string, string>[]; totals: Record<string, string> };
  const headers = Object.keys(report.rows[0] ?? report.totals ?? {});
  return (
    <div>
      <PageHeader title={report.title} description={report.note} />
      <form className="mb-4 flex flex-wrap gap-2">
        <input type="date" name="from" defaultValue={query.from || today} className="h-11 rounded-xl border px-3" />
        <input type="date" name="to" defaultValue={query.to || today} className="h-11 rounded-xl border px-3" />
        {slug === "expiry" ? (
          <select name="window" defaultValue={query.window || "30"} className="h-11 rounded-xl border px-3">
            <option value="30">30 days</option>
            <option value="60">60 days</option>
            <option value="90">90 days</option>
            <option value="expired">Expired</option>
            <option value="quarantine">Quarantine / recall</option>
          </select>
        ) : null}
        {slug === "period_sales" ? (
          <select name="group" defaultValue={query.group || "week"} className="h-11 rounded-xl border px-3">
            <option value="week">Week</option>
            <option value="month">Month</option>
          </select>
        ) : null}
        <button className="rounded-xl bg-brand-700 px-4 text-sm font-semibold text-white">Apply</button>
        <a className="rounded-xl border bg-white px-4 py-3 text-sm" href={`/api/export/report?report=${slug}&from=${query.from || today}&to=${query.to || today}&window=${query.window || "30"}&group=${query.group || "week"}`}>Export CSV</a>
      </form>
      <div className="overflow-x-auto rounded-2xl border bg-white">
        <table className="min-w-full text-sm">
          <thead className="bg-slate-50 text-left text-xs uppercase text-slate-500">
            <tr>{headers.map((header) => <th key={header} className="px-3 py-2">{header.replaceAll("_", " ")}</th>)}</tr>
          </thead>
          <tbody>
            {report.rows.map((row, index) => (
              <tr key={index} className="border-t">
                {headers.map((header) => <td key={header} className="px-3 py-2">{/total|amount|balance|taxable|cgst|sgst|igst|paid|cost|profit|value|refund/.test(header) ? formatINR(row[header]) : String(row[header] ?? "")}</td>)}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="mt-3 text-sm font-semibold">
        {Object.entries(report.totals).map(([key, value]) => <span key={key} className="mr-4">{key.replaceAll("_", " ")}: {formatINR(value)}</span>)}
      </div>
    </div>
  );
}
