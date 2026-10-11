import { NextResponse } from "next/server";
import { can } from "@/lib/permissions";
import { getSessionContext } from "@/lib/tenant";

function cell(value: unknown) {
  const text = value == null ? "" : String(value);
  return /[",\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

export async function GET() {
  const context = await getSessionContext();
  if (!can(context.role, "medicines.view")) {
    return NextResponse.json({ error: "Forbidden" }, { status: 403 });
  }
  const { data, error } = await context.supabase
    .from("medicines")
    .select("medicine_code, name, generic_name, brand_name, manufacturer, composition, strength, dosage_form, pack_size, unit_of_measure, hsn_code, gst_rate, tax_classification, barcode, schedule_category, prescription_required, mrp, default_selling_price, reorder_level, is_active")
    .eq("pharmacy_id", context.pharmacy.id)
    .order("name");
  if (error) return NextResponse.json({ error: "Export failed" }, { status: 500 });
  const rows = data ?? [];
  const headers = Object.keys(rows[0] ?? { medicine_code: "" });
  const csv = [headers.join(","), ...rows.map((row) => headers.map((header) => cell(row[header as keyof typeof row])).join(","))].join("\n");
  return new NextResponse(csv, {
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": "attachment; filename=medicines.csv",
    },
  });
}
