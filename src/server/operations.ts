"use server";

import { revalidatePath } from "next/cache";
import { timingSafeEqual } from "crypto";
import Papa from "papaparse";
import { z } from "zod";
import { mapDbError } from "@/lib/errors";
import { createAdminClient } from "@/lib/supabase/admin";
import { requireAction } from "@/lib/tenant";

const money = z.string().regex(/^\d+(\.\d{1,2})?$/, "Enter a valid amount.");
const qty = z.string().regex(/^\d+(\.\d{1,3})?$/, "Enter a valid quantity.");

function fail(message: string) {
  return { ok: false as const, message };
}

export async function searchMedicines(query: string) {
  const context = await requireAction("medicines.view");
  const { data, error } = await context.supabase.rpc("search_medicines", {
    p_pharmacy: context.pharmacy.id,
    p_query: query,
  });
  if (error) return fail(mapDbError(error));
  return { ok: true as const, data: data as MedicineHit[] };
}

export async function searchCustomers(query: string) {
  const context = await requireAction("customers.view");
  const safe = query.replace(/[%_,.()]/g, "").trim();
  const { data, error } = await context.supabase
    .from("customers")
    .select("id, name, phone, gstin, outstanding_balance, credit_limit")
    .eq("pharmacy_id", context.pharmacy.id)
    .or(`name.ilike.%${safe}%,phone.ilike.%${safe}%`)
    .limit(8);
  if (error) return fail(mapDbError(error));
  return { ok: true as const, data };
}

export type MedicineHit = {
  id: string;
  name: string;
  generic_name: string;
  strength: string;
  dosage_form: string;
  pack_size: string;
  medicine_code: string;
  gst_rate: string;
  tax_classification: string;
  schedule_category: string;
  prescription_required: boolean;
  batches: {
    id: string;
    batch_number: string;
    expiry_date: string;
    qty_available: string;
    mrp: string;
    selling_price: string;
    pack_to_unit: string;
    near_expiry: boolean;
  }[];
};

export async function quoteSale(payload: unknown) {
  const context = await requireAction("billing.create");
  const { data, error } = await context.supabase.rpc("quote_sale", {
    p_payload: { ...(payload as object), pharmacy_id: context.pharmacy.id, preview: true },
  });
  if (error) return fail(mapDbError(error));
  return { ok: true as const, data };
}

const saleSchema = z.object({
  idempotency_key: z.guid(),
  customer_id: z.guid().nullable().optional(),
  customer_name: z.string().max(160).optional(),
  bill_discount_amount: money.optional(),
  acknowledge_near_expiry: z.boolean().optional(),
  prescription_note: z.string().max(200).optional(),
  notes: z.string().max(500).optional(),
  amount_tendered: money.optional(),
  lines: z.array(z.object({
    medicine_id: z.guid(),
    batch_id: z.guid(),
    quantity: qty,
    sold_unit: z.enum(["pack", "unit"]),
    unit_price: money,
    discount_amount: money.optional(),
    discount_percent: z.string().optional(),
  })).min(1).max(80),
  payments: z.array(z.object({
    method: z.enum(["cash", "upi", "card", "bank_transfer", "credit"]),
    amount: money,
    reference: z.string().max(80).optional(),
  })).min(1),
});

export async function completeSale(payload: unknown) {
  const context = await requireAction("billing.create");
  const parsed = saleSchema.safeParse(payload);
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "Check the bill.");
  const { data, error } = await context.supabase.rpc("post_sale", {
    p_payload: { ...parsed.data, pharmacy_id: context.pharmacy.id },
  });
  if (error) return fail(mapDbError(error));
  revalidatePath("/dashboard");
  revalidatePath("/sales");
  revalidatePath("/inventory");
  return { ok: true as const, data };
}

export async function saveDraft(payload: unknown) {
  const context = await requireAction("billing.create");
  const { error } = await context.supabase.from("sales_drafts").insert({
    pharmacy_id: context.pharmacy.id,
    user_id: context.user.id,
    payload,
  });
  if (error) return fail(mapDbError(error));
  return { ok: true as const };
}

const medicineSchema = z.object({
  id: z.string().optional(),
  medicine_code: z.string().trim().max(40).optional(),
  name: z.string().trim().min(1).max(200),
  generic_name: z.string().trim().max(200).optional(),
  brand_name: z.string().trim().max(200).optional(),
  manufacturer: z.string().trim().max(160).optional(),
  composition: z.string().trim().max(500).optional(),
  strength: z.string().trim().max(80).optional(),
  dosage_form: z.string().trim().min(1).max(40),
  pack_size: z.string().trim().max(80).optional(),
  unit_of_measure: z.string().trim().max(40).optional(),
  hsn_code: z.string().trim().max(12).optional(),
  gst_rate: z.coerce.number().min(0).max(100),
  tax_classification: z.enum(["taxable", "exempt", "nil", "zero"]),
  barcode: z.string().trim().max(40).optional(),
  schedule_category: z.enum(["OTC", "H", "H1", "X", "G"]),
  prescription_required: z.boolean().optional(),
  mrp: z.coerce.number().min(0),
  default_selling_price: z.coerce.number().min(0),
  reorder_level: z.coerce.number().min(0),
  is_active: z.boolean().optional(),
  acknowledge_duplicate: z.boolean().optional(),
});

export async function saveMedicine(payload: unknown) {
  const context = await requireAction("medicines.manage");
  const parsed = medicineSchema.safeParse(payload);
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "Check the medicine.");
  const input = parsed.data;
  if (input.default_selling_price > input.mrp) return fail("The selling price cannot be above MRP.");
  const { data: duplicates } = await context.supabase.rpc("find_medicine_duplicates", {
    p_pharmacy: context.pharmacy.id,
    p_name: input.name,
    p_strength: input.strength ?? "",
    p_dosage_form: input.dosage_form,
    p_pack_size: input.pack_size ?? "",
    p_barcode: input.barcode ?? "",
    p_exclude: input.id || null,
  });
  if (Array.isArray(duplicates) && duplicates.length > 0 && !input.acknowledge_duplicate) {
    return { ok: false as const, message: "A medicine with the same name, strength, form, and pack already exists.", duplicates };
  }
  let code = input.medicine_code?.trim() ?? "";
  if (!code && !input.id) {
    const { data: nextCode, error: codeError } = await context.supabase.rpc("next_medicine_code", { p_pharmacy: context.pharmacy.id });
    if (codeError || !nextCode) return fail(mapDbError(codeError));
    code = String(nextCode);
  }
  const row = {
    pharmacy_id: context.pharmacy.id,
    medicine_code: code || undefined,
    name: input.name,
    generic_name: input.generic_name ?? "",
    brand_name: input.brand_name ?? "",
    manufacturer: input.manufacturer ?? "",
    composition: input.composition ?? "",
    strength: input.strength ?? "",
    dosage_form: input.dosage_form,
    pack_size: input.pack_size ?? "",
    unit_of_measure: input.unit_of_measure ?? "pack",
    hsn_code: input.hsn_code ?? "",
    gst_rate: input.gst_rate,
    tax_classification: input.tax_classification,
    barcode: input.barcode || null,
    schedule_category: input.schedule_category,
    prescription_required: Boolean(input.prescription_required || ["H", "H1", "X", "G"].includes(input.schedule_category)),
    mrp: input.mrp,
    default_selling_price: input.default_selling_price,
    reorder_level: input.reorder_level,
    is_active: input.is_active ?? true,
  };
  const query = input.id
    ? context.supabase.from("medicines").update(row).eq("id", input.id).eq("pharmacy_id", context.pharmacy.id)
    : context.supabase.from("medicines").insert(row);
  const { error } = await query;
  if (error) return fail(mapDbError(error));
  revalidatePath("/medicines");
  return { ok: true as const };
}

export async function importMedicines(csv: string) {
  const context = await requireAction("medicines.manage");
  const parsed = Papa.parse<Record<string, string>>(csv, { header: true, skipEmptyLines: true });
  const errors: { row: number; message: string }[] = [];
  let imported = 0;
  for (const [index, row] of parsed.data.entries()) {
    const result = await saveMedicine({
      name: row.name,
      generic_name: row.generic_name,
      brand_name: row.brand_name,
      manufacturer: row.manufacturer,
      composition: row.composition,
      strength: row.strength,
      dosage_form: row.dosage_form || "tablet",
      pack_size: row.pack_size,
      unit_of_measure: row.unit_of_measure || "pack",
      hsn_code: row.hsn_code,
      gst_rate: row.gst_rate || "0",
      tax_classification: row.tax_classification || "taxable",
      barcode: row.barcode,
      schedule_category: row.schedule_category || "OTC",
      prescription_required: row.prescription_required === "true",
      mrp: row.mrp || "0",
      default_selling_price: row.default_selling_price || row.mrp || "0",
      reorder_level: row.reorder_level || "0",
      medicine_code: row.medicine_code,
      acknowledge_duplicate: false,
    });
    if (!result.ok) errors.push({ row: index + 2, message: result.message });
    else imported += 1;
  }
  return { ok: true as const, imported, errors };
}

const partySchema = z.object({
  id: z.string().nullish(),
  name: z.string().trim().min(1).max(160),
  phone: z.string().trim().max(20).nullish(),
  email: z.string().trim().max(120).nullish(),
  address: z.string().trim().max(300).nullish(),
  state: z.string().trim().max(80).nullish(),
  state_code: z.string().trim().max(2).nullish(),
  gstin: z.string().trim().max(15).nullish(),
  contact_person: z.string().trim().max(120).nullish(),
  drug_licence: z.string().trim().max(120).nullish(),
  payment_terms: z.string().trim().max(120).nullish(),
  opening_balance: z.coerce.number().optional(),
  credit_limit: z.coerce.number().min(0).optional(),
});

export async function saveSupplier(payload: unknown) {
  const context = await requireAction("suppliers.manage");
  const parsed = partySchema.safeParse(payload);
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "Check the supplier.");
  const row = {
    pharmacy_id: context.pharmacy.id,
    name: parsed.data.name,
    phone: parsed.data.phone ?? "",
    email: parsed.data.email ?? "",
    address: parsed.data.address ?? "",
    state: parsed.data.state ?? "",
    state_code: parsed.data.state_code || null,
    gstin: parsed.data.gstin || null,
    contact_person: parsed.data.contact_person ?? "",
    drug_licence: parsed.data.drug_licence ?? "",
    payment_terms: parsed.data.payment_terms ?? "",
    ...(parsed.data.id ? {} : { opening_balance: parsed.data.opening_balance ?? 0 }),
  };
  const query = parsed.data.id
    ? context.supabase.from("suppliers").update(row).eq("id", parsed.data.id)
    : context.supabase.from("suppliers").insert(row);
  const { error } = await query;
  if (error) return fail(mapDbError(error));
  revalidatePath("/suppliers");
  return { ok: true as const };
}

export async function saveCustomer(payload: unknown) {
  const context = await requireAction("customers.manage");
  const parsed = partySchema.safeParse(payload);
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "Check the customer.");
  const row = {
    pharmacy_id: context.pharmacy.id,
    name: parsed.data.name,
    phone: parsed.data.phone ?? "",
    address: parsed.data.address ?? "",
    gstin: parsed.data.gstin || null,
    state_code: parsed.data.state_code || null,
    credit_limit: parsed.data.credit_limit ?? 0,
    ...(parsed.data.id ? {} : { opening_balance: parsed.data.opening_balance ?? 0 }),
  };
  const query = parsed.data.id
    ? context.supabase.from("customers").update(row).eq("id", parsed.data.id)
    : context.supabase.from("customers").insert(row);
  const { error } = await query;
  if (error) return fail(mapDbError(error));
  revalidatePath("/customers");
  return { ok: true as const };
}

export async function postPurchase(payload: unknown) {
  const context = await requireAction("purchases.manage");
  const { data, error } = await context.supabase.rpc("post_purchase", {
    p_payload: { ...(payload as object), pharmacy_id: context.pharmacy.id },
  });
  if (error) return fail(mapDbError(error));
  revalidatePath("/purchases");
  revalidatePath("/inventory");
  revalidatePath("/suppliers");
  return { ok: true as const, data };
}

export async function postSaleReturn(payload: unknown) {
  const context = await requireAction("returns.manage");
  const { data, error } = await context.supabase.rpc("post_sale_return", {
    p_payload: { ...(payload as object), pharmacy_id: context.pharmacy.id },
  });
  if (error) return fail(mapDbError(error));
  revalidatePath("/returns");
  revalidatePath("/sales");
  revalidatePath("/inventory");
  return { ok: true as const, data };
}

export async function postPurchaseReturn(payload: unknown) {
  const context = await requireAction("purchases.manage");
  const { data, error } = await context.supabase.rpc("post_purchase_return", {
    p_payload: { ...(payload as object), pharmacy_id: context.pharmacy.id },
  });
  if (error) return fail(mapDbError(error));
  revalidatePath("/purchases");
  revalidatePath("/inventory");
  return { ok: true as const, data };
}

export async function adjustStock(payload: unknown) {
  const context = await requireAction("inventory.adjust");
  const { data, error } = await context.supabase.rpc("post_stock_adjustment", {
    p_payload: { ...(payload as object), pharmacy_id: context.pharmacy.id },
  });
  if (error) return fail(mapDbError(error));
  revalidatePath("/inventory");
  return { ok: true as const, data };
}

export async function recordSupplierPayment(payload: unknown) {
  const context = await requireAction("suppliers.manage");
  const { error } = await context.supabase.rpc("record_supplier_payment", {
    p_payload: { ...(payload as object), pharmacy_id: context.pharmacy.id },
  });
  if (error) return fail(mapDbError(error));
  revalidatePath("/suppliers");
  return { ok: true as const };
}

export async function recordCustomerReceipt(payload: unknown) {
  const context = await requireAction("customers.manage");
  const { error } = await context.supabase.rpc("record_customer_receipt", {
    p_payload: { ...(payload as object), pharmacy_id: context.pharmacy.id },
  });
  if (error) return fail(mapDbError(error));
  revalidatePath("/customers");
  return { ok: true as const };
}

const settingsSchema = z.object({
  name: z.string().trim().min(1).max(160),
  owner_name: z.string().trim().max(160),
  address_line1: z.string().trim().max(160),
  address_line2: z.string().trim().max(160),
  city: z.string().trim().max(80),
  state: z.string().trim().max(80),
  state_code: z.string().regex(/^\d{2}$/),
  pincode: z.string().trim().max(10),
  gstin: z.string().trim().max(15).optional(),
  gst_registered: z.boolean(),
  drug_licence_numbers: z.string().trim().max(200),
  phone: z.string().trim().max(20),
  email: z.string().trim().max(120),
  invoice_prefix: z.string().trim().regex(/^[A-Z0-9]{1,8}$/),
  financial_year_start_month: z.coerce.number().int().min(1).max(12),
  pricing_mode: z.enum(["inclusive", "exclusive"]),
  default_payment_method: z.enum(["cash", "upi", "card", "bank_transfer"]),
  round_invoice_to_rupee: z.boolean(),
  low_stock_threshold: z.coerce.number().min(0),
  near_expiry_days: z.coerce.number().int().min(1).max(365),
  allow_negative_stock: z.boolean(),
  allow_credit_sales: z.boolean(),
  max_operator_discount_percent: z.coerce.number().min(0).max(100),
  max_pharmacist_discount_percent: z.coerce.number().min(0).max(100),
  invoice_footer: z.string().max(400),
  timezone: z.string().min(1),
  logo_url: z.string().max(400000).optional(),
});

export async function saveSettings(payload: unknown) {
  const context = await requireAction("settings.manage");
  const parsed = settingsSchema.safeParse(payload);
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "Check the settings.");
  const { logo_url, ...settings } = parsed.data;
  const { error } = await context.supabase.from("pharmacies").update({
    ...settings,
    gstin: parsed.data.gstin || null,
    ...(logo_url ? { logo_url } : {}),
  }).eq("id", context.pharmacy.id);
  if (error) return fail(mapDbError(error));
  revalidatePath("/settings");
  return { ok: true as const };
}

export async function inviteUser(payload: unknown) {
  const context = await requireAction("users.manage");
  const parsed = z.object({
    full_name: z.string().trim().min(1),
    email: z.email(),
    password: z.string().min(8),
    role: z.enum(["pharmacist", "billing_operator", "owner"]),
  }).safeParse(payload);
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "Check the user.");
  const admin = createAdminClient();
  const { data, error } = await admin.auth.admin.createUser({
    email: parsed.data.email,
    password: parsed.data.password,
    email_confirm: true,
    user_metadata: { full_name: parsed.data.full_name },
  });
  if (error || !data.user) return fail("The user could not be created. The email may already be registered.");
  const { error: memberError } = await admin.from("pharmacy_memberships").insert({
    pharmacy_id: context.pharmacy.id,
    user_id: data.user.id,
    role: parsed.data.role,
  });
  if (memberError) return fail(mapDbError(memberError));
  revalidatePath("/settings");
  return { ok: true as const };
}

function sameSecret(input: string, expected: string) {
  const left = Buffer.from(input);
  const right = Buffer.from(expected);
  return left.length === right.length && timingSafeEqual(left, right);
}

export async function bootstrapStore(payload: unknown) {
  const parsed = z.object({
    secret: z.string().min(16),
    pharmacy_name: z.string().trim().min(1).max(160),
    owner_name: z.string().trim().min(1),
    email: z.email(),
    password: z.string().min(8),
    state: z.string().min(1),
    state_code: z.string().regex(/^\d{2}$/),
    gstin: z.string().optional(),
  }).safeParse(payload);
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "Check the setup form.");
  const expected = process.env.BOOTSTRAP_SECRET ?? "";
  if (!expected || !sameSecret(parsed.data.secret, expected)) return fail("The setup secret is not valid.");
  const admin = createAdminClient();
  const { count, error: pharmacyCountError } = await admin.from("pharmacies").select("id", { count: "exact", head: true });
  if (pharmacyCountError) return fail("Apply the SQL migrations in Supabase before creating the owner. The pharmacy tables are not there yet.");
  if ((count ?? 0) > 0) return fail("A pharmacy already exists. Sign in as the owner to add staff.");
  const { data, error } = await admin.auth.admin.createUser({
    email: parsed.data.email,
    password: parsed.data.password,
    email_confirm: true,
    user_metadata: { full_name: parsed.data.owner_name },
  });
  let userId = data?.user?.id;
  if (!userId) {
    const listed = await admin.auth.admin.listUsers({ page: 1, perPage: 200 });
    userId = listed.data.users.find((user) => user.email?.toLowerCase() === parsed.data.email.toLowerCase())?.id;
  }
  if (error && !userId) return fail("The owner account could not be created.");
  if (!userId) return fail("The owner account could not be created.");
  const { data: pharmacy, error: pharmacyError } = await admin.from("pharmacies").insert({
    name: parsed.data.pharmacy_name,
    owner_name: parsed.data.owner_name,
    email: parsed.data.email,
    state: parsed.data.state,
    state_code: parsed.data.state_code,
    gstin: parsed.data.gstin || null,
    gst_registered: Boolean(parsed.data.gstin),
  }).select("id").single();
  if (pharmacyError || !pharmacy) return fail("The pharmacy could not be created.");
  const { error: memberError } = await admin.from("pharmacy_memberships").insert({
    pharmacy_id: pharmacy.id,
    user_id: userId,
    role: "owner",
  });
  if (memberError) return fail("The owner membership could not be created.");
  return { ok: true as const };
}
