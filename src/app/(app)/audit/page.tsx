import { PageHeader } from "@/components/page-header";
import { formatDateTime } from "@/lib/format";
import { requireAction } from "@/lib/tenant";

export default async function AuditPage() {
  const context = await requireAction("audit.view");
  const { data } = await context.supabase.from("audit_logs").select("id, action, entity_type, created_at, metadata").eq("pharmacy_id", context.pharmacy.id).order("created_at", { ascending: false }).limit(100);
  return (
    <div>
      <PageHeader title="Audit log" description="Stock adjustments, posted bills, returns, settings, and staff changes are recorded here." />
      <ul className="divide-y rounded-2xl border bg-white">
        {(data ?? []).map((row) => (
          <li key={row.id} className="px-4 py-3 text-sm">
            <span className="font-medium">{row.action}</span> · {row.entity_type} · {formatDateTime(row.created_at, context.pharmacy.timezone)}
          </li>
        ))}
      </ul>
    </div>
  );
}
