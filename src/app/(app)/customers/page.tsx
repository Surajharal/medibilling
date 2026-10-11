import Link from "next/link";
import { PartyForm } from "@/components/party-form";
import { PageHeader } from "@/components/page-header";
import { formatINR } from "@/lib/format";
import { requireAction } from "@/lib/tenant";

export default async function CustomersPage() {
  const context = await requireAction("customers.view");
  const { data } = await context.supabase.from("customers").select("id, name, phone, outstanding_balance").eq("pharmacy_id", context.pharmacy.id).order("name");
  return (
    <div className="space-y-6">
      <PageHeader title="Customers" description="Collect only the details needed for billing, credit, and reprints." />
      <ul className="divide-y rounded-2xl border bg-white">
        {(data ?? []).map((customer) => (
          <li key={customer.id} className="flex justify-between px-4 py-3 text-sm">
            <Link className="font-medium text-brand-800" href={`/customers/${customer.id}`}>{customer.name}</Link>
            <span>{customer.phone} · due {formatINR(customer.outstanding_balance)}</span>
          </li>
        ))}
      </ul>
      <PartyForm kind="customer" />
    </div>
  );
}
