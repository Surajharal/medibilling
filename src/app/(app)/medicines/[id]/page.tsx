import { notFound } from "next/navigation";
import { MedicineForm } from "@/components/medicine-form";
import { PageHeader } from "@/components/page-header";
import { formatDateOnly, formatINR, formatQty } from "@/lib/format";
import { can } from "@/lib/permissions";
import { requireAction } from "@/lib/tenant";

export default async function MedicineDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const context = await requireAction("medicines.view");
  const { data: medicine } = await context.supabase.from("medicines").select("*").eq("id", id).eq("pharmacy_id", context.pharmacy.id).maybeSingle();
  if (!medicine) notFound();
  const { data: batches } = await context.supabase.from("inventory_batches").select("*").eq("medicine_id", id).order("expiry_date");
  const { data: movements } = await context.supabase.from("stock_movements").select("*").eq("medicine_id", id).order("created_at", { ascending: false }).limit(30);
  return (
    <div className="space-y-6">
      <PageHeader title={medicine.name} description={`${medicine.strength} ${medicine.dosage_form} · ${medicine.generic_name || "No generic name"}`} />
      {can(context.role, "medicines.manage") ? <MedicineForm initial={medicine} /> : null}
      <section>
        <h2 className="mb-2 font-semibold">Batches</h2>
        <div className="overflow-x-auto rounded-2xl border bg-white">
          <table className="min-w-full text-sm">
            <thead className="bg-slate-50 text-left text-xs uppercase text-slate-500"><tr><th className="px-3 py-2">Batch</th><th>Expiry</th><th>Available</th><th>Quarantine</th><th>MRP</th><th>Cost</th><th>Status</th></tr></thead>
            <tbody>
              {(batches ?? []).map((batch) => (
                <tr key={batch.id} className="border-t">
                  <td className="px-3 py-2">{batch.batch_number}</td>
                  <td>{formatDateOnly(batch.expiry_date)}</td>
                  <td>{formatQty(batch.qty_available)}</td>
                  <td>{formatQty(batch.qty_quarantine)}</td>
                  <td>{formatINR(batch.mrp)}</td>
                  <td>{formatINR(batch.unit_cost)}</td>
                  <td>{batch.status}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
      <section>
        <h2 className="mb-2 font-semibold">Recent stock movements</h2>
        <ul className="space-y-1 text-sm">
          {(movements ?? []).map((movement) => (
            <li key={movement.id}>{movement.movement_type} · {formatQty(movement.quantity_delta)} · balance {formatQty(movement.quantity_after)}</li>
          ))}
        </ul>
      </section>
    </div>
  );
}
