"use client";

import { useState } from "react";
import { toast } from "sonner";
import { INDIAN_STATES } from "@/lib/catalog";
import { Button } from "@/components/ui/button";
import { Field, Input, Select, Textarea } from "@/components/ui/inputs";
import type { PharmacyRecord } from "@/lib/tenant";
import { inviteUser, saveSettings } from "@/server/operations";

export function SettingsForm({ pharmacy }: { pharmacy: PharmacyRecord }) {
  const [pending, setPending] = useState(false);
  const [logo, setLogo] = useState<string | undefined>();

  async function onSubmit(formData: FormData) {
    setPending(true);
    const result = await saveSettings({
      name: formData.get("name"),
      owner_name: formData.get("owner_name"),
      address_line1: formData.get("address_line1"),
      address_line2: formData.get("address_line2"),
      city: formData.get("city"),
      state: INDIAN_STATES.find((item) => item.code === formData.get("state_code"))?.name ?? pharmacy.state,
      state_code: formData.get("state_code"),
      pincode: formData.get("pincode"),
      gstin: formData.get("gstin"),
      gst_registered: formData.get("gst_registered") === "on",
      drug_licence_numbers: formData.get("drug_licence_numbers"),
      phone: formData.get("phone"),
      email: formData.get("email"),
      invoice_prefix: String(formData.get("invoice_prefix") ?? "").toUpperCase(),
      financial_year_start_month: formData.get("financial_year_start_month"),
      pricing_mode: formData.get("pricing_mode"),
      default_payment_method: formData.get("default_payment_method"),
      round_invoice_to_rupee: formData.get("round_invoice_to_rupee") === "on",
      low_stock_threshold: formData.get("low_stock_threshold"),
      near_expiry_days: formData.get("near_expiry_days"),
      allow_negative_stock: formData.get("allow_negative_stock") === "on",
      allow_credit_sales: formData.get("allow_credit_sales") === "on",
      max_operator_discount_percent: formData.get("max_operator_discount_percent"),
      max_pharmacist_discount_percent: formData.get("max_pharmacist_discount_percent"),
      invoice_footer: formData.get("invoice_footer"),
      timezone: formData.get("timezone"),
      logo_url: logo,
    });
    setPending(false);
    if (!result.ok) toast.error(result.message);
    else toast.success("Settings saved");
  }

  return (
    <form action={onSubmit} className="grid gap-3 rounded-2xl border bg-white p-5 md:grid-cols-2">
      <Field label="Pharmacy name"><Input name="name" defaultValue={pharmacy.name} required /></Field>
      <Field label="Owner name"><Input name="owner_name" defaultValue={pharmacy.owner_name} /></Field>
      <Field label="Address"><Input name="address_line1" defaultValue={pharmacy.address_line1} /></Field>
      <Field label="Address line 2"><Input name="address_line2" defaultValue={pharmacy.address_line2} /></Field>
      <Field label="City"><Input name="city" defaultValue={pharmacy.city} /></Field>
      <Field label="State"><Select name="state_code" defaultValue={pharmacy.state_code}>{INDIAN_STATES.map((state) => <option key={state.code} value={state.code}>{state.name}</option>)}</Select></Field>
      <Field label="PIN code"><Input name="pincode" defaultValue={pharmacy.pincode} /></Field>
      <Field label="Phone"><Input name="phone" defaultValue={pharmacy.phone} /></Field>
      <Field label="Email"><Input name="email" defaultValue={pharmacy.email} /></Field>
      <Field label="GSTIN"><Input name="gstin" defaultValue={pharmacy.gstin ?? ""} /></Field>
      <Field label="Drug licences"><Input name="drug_licence_numbers" defaultValue={pharmacy.drug_licence_numbers} /></Field>
      <Field label="Invoice prefix"><Input name="invoice_prefix" defaultValue={pharmacy.invoice_prefix} /></Field>
      <Field label="Financial year start month"><Input name="financial_year_start_month" type="number" min={1} max={12} defaultValue={pharmacy.financial_year_start_month} /></Field>
      <Field label="GST pricing mode" hint="Inclusive means the entered price already contains GST.">
        <Select name="pricing_mode" defaultValue={pharmacy.pricing_mode}><option value="inclusive">GST inclusive</option><option value="exclusive">GST exclusive</option></Select>
      </Field>
      <Field label="Default payment"><Select name="default_payment_method" defaultValue={pharmacy.default_payment_method}><option value="cash">Cash</option><option value="upi">UPI</option><option value="card">Card</option><option value="bank_transfer">Bank transfer</option></Select></Field>
      <Field label="Low-stock threshold"><Input name="low_stock_threshold" defaultValue={pharmacy.low_stock_threshold} /></Field>
      <Field label="Near-expiry days"><Input name="near_expiry_days" defaultValue={pharmacy.near_expiry_days} /></Field>
      <Field label="Operator discount limit %"><Input name="max_operator_discount_percent" defaultValue={pharmacy.max_operator_discount_percent} /></Field>
      <Field label="Pharmacist discount limit %"><Input name="max_pharmacist_discount_percent" defaultValue={pharmacy.max_pharmacist_discount_percent} /></Field>
      <Field label="Time zone"><Input name="timezone" defaultValue={pharmacy.timezone} /></Field>
      <div className="md:col-span-2"><Field label="Invoice footer"><Textarea name="invoice_footer" defaultValue={pharmacy.invoice_footer} /></Field></div>
      <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="gst_registered" defaultChecked={pharmacy.gst_registered} /> GST registered</label>
      <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="round_invoice_to_rupee" defaultChecked={pharmacy.round_invoice_to_rupee} /> Round invoice total to the rupee</label>
      <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="allow_credit_sales" defaultChecked={pharmacy.allow_credit_sales} /> Allow credit sales</label>
      <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="allow_negative_stock" defaultChecked={pharmacy.allow_negative_stock} /> Owner may post audited negative stock</label>
      <Field label="Logo" hint="PNG, JPEG, or WebP under 250 KB.">
        <Input type="file" accept="image/png,image/jpeg,image/webp" onChange={(event) => {
          const file = event.target.files?.[0];
          if (!file) return;
          if (file.size > 250000) {
            toast.error("Logo must be under 250 KB.");
            return;
          }
          const reader = new FileReader();
          reader.onload = () => setLogo(String(reader.result));
          reader.readAsDataURL(file);
        }} />
      </Field>
      <div className="md:col-span-2"><Button disabled={pending}>{pending ? "Saving..." : "Save settings"}</Button></div>
    </form>
  );
}

export function InviteForm() {
  const [pending, setPending] = useState(false);
  async function onSubmit(formData: FormData) {
    setPending(true);
    const result = await inviteUser({
      full_name: formData.get("full_name"),
      email: formData.get("email"),
      password: formData.get("password"),
      role: formData.get("role"),
    });
    setPending(false);
    if (!result.ok) toast.error(result.message);
    else toast.success("Staff account created");
  }
  return (
    <form action={onSubmit} className="grid max-w-xl gap-3 rounded-2xl border bg-white p-5">
      <h2 className="font-semibold">Add staff</h2>
      <Field label="Name"><Input name="full_name" required /></Field>
      <Field label="Email"><Input name="email" type="email" required /></Field>
      <Field label="Temporary password"><Input name="password" type="password" minLength={8} required /></Field>
      <Field label="Role"><Select name="role"><option value="pharmacist">Pharmacist</option><option value="billing_operator">Billing operator</option><option value="owner">Owner</option></Select></Field>
      <Button disabled={pending}>Create account</Button>
    </form>
  );
}
