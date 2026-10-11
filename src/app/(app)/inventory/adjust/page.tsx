import { AdjustmentForm } from "@/components/adjustment-form";
import { PageHeader } from "@/components/page-header";
import { formatDateOnly } from "@/lib/format";
import { requireAction } from "@/lib/tenant";

export default async function AdjustPage() {
  const context = await requireAction("inventory.adjust");
  const { data } = await context.supabase.from("inventory_batches").select("id, batch_number, expiry_date, qty_available, medicines(name, strength)").eq("pharmacy_id", context.pharmacy.id).order("expiry_date").limit(300);
  const batches = (data ?? []).map((batch) => ({
    id: batch.id as string,
    label: `${(batch.medicines as { name?: string; strength?: string } | null)?.name ?? "Medicine"} ${(batch.medicines as { strength?: string } | null)?.strength ?? ""} · ${batch.batch_number} · exp ${formatDateOnly(batch.expiry_date)} · qty ${batch.qty_available}`,
  }));
  return (
    <div>
      <PageHeader title="Stock adjustment" description="Every correction needs a reason and is written to the audit log and stock ledger." />
      <AdjustmentForm batches={batches} />
    </div>
  );
}
