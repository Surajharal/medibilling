import Link from "next/link";
import { PageHeader } from "@/components/page-header";
import { requireAction } from "@/lib/tenant";

const REPORTS = [
  ["daily_sales", "Daily sales"],
  ["period_sales", "Weekly and monthly sales"],
  ["sales_by_medicine", "Sales by medicine"],
  ["sales_by_batch", "Sales by batch"],
  ["sales_by_customer", "Sales by customer"],
  ["sales_by_operator", "Sales by operator"],
  ["gst_summary", "GST summary"],
  ["purchases", "Purchases"],
  ["supplier_outstanding", "Supplier outstanding"],
  ["customer_outstanding", "Customer outstanding"],
  ["low_stock", "Low stock"],
  ["expiry", "Expiry and blocked stock"],
  ["stock_valuation", "Stock valuation"],
  ["returns", "Returns and refunds"],
  ["payments", "Payment methods"],
  ["gross_profit", "Estimated gross profit"],
];

export default async function ReportsPage() {
  await requireAction("reports.view");
  return (
    <div>
      <PageHeader title="Reports" description="Totals are calculated from posted transactions for the full date range." />
      <div className="grid gap-3 sm:grid-cols-2">
        {REPORTS.map(([slug, label]) => (
          <Link key={slug} href={`/reports/${slug}`} className="rounded-2xl border bg-white p-4 font-medium hover:border-brand-400">{label}</Link>
        ))}
      </div>
    </div>
  );
}
