import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { can, isRole, type Action, type Role } from "@/lib/permissions";

export type PharmacyRecord = {
  id: string;
  name: string;
  owner_name: string;
  address_line1: string;
  address_line2: string;
  city: string;
  state: string;
  state_code: string;
  pincode: string;
  gstin: string | null;
  gst_registered: boolean;
  drug_licence_numbers: string;
  phone: string;
  email: string;
  logo_url: string | null;
  timezone: string;
  invoice_prefix: string;
  financial_year_start_month: number;
  pricing_mode: "inclusive" | "exclusive";
  default_payment_method: string;
  round_invoice_to_rupee: boolean;
  low_stock_threshold: number;
  near_expiry_days: number;
  allow_negative_stock: boolean;
  allow_credit_sales: boolean;
  max_operator_discount_percent: number;
  max_pharmacist_discount_percent: number;
  invoice_footer: string;
};

export async function getSessionContext() {
  const supabase = await createClient();
  const { data } = await supabase.auth.getUser();
  if (!data.user) redirect("/login");
  const { data: memberships } = await supabase
    .from("pharmacy_memberships")
    .select("role, pharmacy_id, pharmacies(*)")
    .eq("user_id", data.user.id)
    .eq("is_active", true);
  const rows = memberships ?? [];
  if (rows.length === 0) redirect("/pending");
  const cookieStore = await cookies();
  const preferred = cookieStore.get("mb_pharmacy")?.value;
  const current = rows.find((row) => row.pharmacy_id === preferred) ?? rows[0];
  const pharmacy = current.pharmacies as unknown as PharmacyRecord;
  const role = isRole(current.role) ? current.role : "billing_operator";
  return {
    supabase,
    user: data.user,
    role,
    pharmacy,
    memberships: rows.map((row) => ({
      role: row.role as Role,
      pharmacyId: row.pharmacy_id,
      name: (row.pharmacies as unknown as PharmacyRecord)?.name ?? "Store",
    })),
  };
}

export async function requireAction(action: Action) {
  const context = await getSessionContext();
  if (!can(context.role, action)) redirect("/forbidden");
  return context;
}
