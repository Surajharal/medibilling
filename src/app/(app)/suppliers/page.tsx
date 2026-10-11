import Link from "next/link";
import { PartyForm } from "@/components/party-form";
import { PageHeader } from "@/components/page-header";
import { formatINR } from "@/lib/format";
import { requireAction } from "@/lib/tenant";

export default async function SuppliersPage() {
  const context = await requireAction("suppliers.manage");
  const { data } = await context.supabase.from("suppliers").select("id, name, phone, current_balance").eq("pharmacy_id", context.pharmacy.id).order("name");
  return (
    <div className="space-y-6">
      <PageHeader title="Suppliers" />
      <ul className="divide-y rounded-2xl border bg-white">
        {(data ?? []).map((supplier) => (
          <li key={supplier.id} className="flex justify-between px-4 py-3 text-sm">
            <Link className="font-medium text-brand-800" href={`/suppliers/${supplier.id}`}>{supplier.name}</Link>
            <span>{supplier.phone} · due {formatINR(supplier.current_balance)}</span>
          </li>
        ))}
      </ul>
      <PartyForm kind="supplier" />
    </div>
  );
}
