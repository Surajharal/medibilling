import { NextResponse } from "next/server";
import { can } from "@/lib/permissions";
import { todayInTimeZone } from "@/lib/format";
import { getSessionContext } from "@/lib/tenant";

function cell(value: unknown) {
  const text = value == null ? "" : String(value);
  return /[",\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

export async function GET(request: Request) {
  const context = await getSessionContext();
  const url = new URL(request.url);
  const report = url.searchParams.get("report") ?? "";
  const action = report === "gross_profit" ? "reports.profit" : "reports.view";
  if (!can(context.role, action)) {
    return NextResponse.json({ error: "Forbidden" }, { status: 403 });
  }
  const today = todayInTimeZone(context.pharmacy.timezone);
  const { data, error } = await context.supabase.rpc("report_query", {
    p_pharmacy: context.pharmacy.id,
    p_report: report,
    p_from: url.searchParams.get("from") || today,
    p_to: url.searchParams.get("to") || today,
    p_extra: { window: url.searchParams.get("window") || "30", group: url.searchParams.get("group") || "week" },
  });
  if (error || !data) return NextResponse.json({ error: "Export failed" }, { status: 400 });
  const body = data as { rows: Record<string, string>[] };
  const rows = body.rows ?? [];
  const headers = Object.keys(rows[0] ?? {});
  const csv = [headers.join(","), ...rows.map((row) => headers.map((header) => cell(row[header])).join(","))].join("\n");
  return new NextResponse(csv, {
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": `attachment; filename=${report}.csv`,
    },
  });
}
