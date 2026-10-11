import { notFound } from "next/navigation";
import { SupplierPayment } from "@/components/supplier-payment";
import { PageHeader } from "@/components/page-header";
import { formatINR } from "@/lib/format";
import { requireAction } from "@/lib/tenant";

export default async function SupplierPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const context = await requireAction("suppliers.manage");
  const { data: supplier } = await context.supabase.from("suppliers").select("*").eq("id", id).eq("pharmacy_id", context.pharmacy.id).maybeSingle();
  if (!supplier) notFound();
  const { data: ledger } = await context.supabase.from("supplier_ledger_entries").select("*").eq("supplier_id", id).order("created_at", { ascending: false }).limit(30);
  return (
    <div>
      <PageHeader title={supplier.name} description={`Payable ${formatINR(supplier.current_balance)}`} />
      <SupplierPayment supplierId={id} />
      <ul className="mt-6 space-y-2 text-sm">
        {(ledger ?? []).map((entry) => <li key={entry.id}>{entry.entry_type} · debit {formatINR(entry.debit)} · credit {formatINR(entry.credit)}</li>)}
      </ul>
    </div>
  );
}
