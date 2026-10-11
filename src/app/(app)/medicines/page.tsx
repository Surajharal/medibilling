import Link from "next/link";
import { MedicinesTable, type MedicineRow } from "@/components/medicines-table";
import { PageHeader, Pager } from "@/components/page-header";
import { safeSearch } from "@/lib/catalog";
import { can } from "@/lib/permissions";
import { requireAction } from "@/lib/tenant";

export default async function MedicinesPage({ searchParams }: { searchParams: Promise<{ q?: string; page?: string }> }) {
  const params = await searchParams;
  const context = await requireAction("medicines.view");
  const page = Math.max(1, Number(params.page ?? 1));
  const q = safeSearch(params.q ?? "");
  const from = (page - 1) * 20;
  let query = context.supabase.from("medicines").select("id, medicine_code, name, strength, dosage_form, gst_rate, mrp, is_active", { count: "exact" }).eq("pharmacy_id", context.pharmacy.id).order("name").range(from, from + 20);
  if (q) query = query.or(`name.ilike.%${q}%,generic_name.ilike.%${q}%,brand_name.ilike.%${q}%,medicine_code.ilike.%${q}%,manufacturer.ilike.%${q}%,barcode.eq.${q}`);
  const { data, count } = await query;
  const fetched = (data ?? []) as MedicineRow[];
  const rows = fetched.slice(0, 20);
  return (
    <div>
      <PageHeader title="Medicines" description="Each strength, form, and pack is a separate medicine." action={can(context.role, "medicines.manage") ? <Link className="rounded-xl bg-brand-700 px-4 py-3 text-sm font-semibold text-white" href="/medicines/new">Add medicine</Link> : null} />
      <form className="mb-4 flex gap-2">
        <input name="q" defaultValue={q} placeholder="Search brand, generic, code, barcode" className="h-11 flex-1 rounded-xl border px-3" />
        <button className="rounded-xl border bg-white px-4 text-sm font-semibold">Search</button>
        <a className="rounded-xl border bg-white px-4 py-3 text-sm" href="/api/export/medicines">Export CSV</a>
        {can(context.role, "medicines.manage") ? <Link className="rounded-xl border bg-white px-4 py-3 text-sm" href="/medicines/import">Import</Link> : null}
      </form>
      <MedicinesTable rows={rows} />
      <Pager page={page} hasMore={fetched.length > 20} path="/medicines" query={{ q }} />
      <p className="mt-2 text-xs text-slate-500">{count ?? 0} medicines</p>
    </div>
  );
}
