"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { toast } from "sonner";
import { DOSAGE_FORMS, SCHEDULES } from "@/lib/catalog";
import { Button } from "@/components/ui/button";
import { Field, Input, Select, Textarea } from "@/components/ui/inputs";
import { lookupMedicine } from "@/server/medicine-lookup";
import { saveMedicine } from "@/server/operations";

export function MedicineForm({ initial }: { initial?: Record<string, string | number | boolean | null> }) {
  const router = useRouter();
  const [pending, setPending] = useState(false);
  const [looking, setLooking] = useState(false);
  const [acknowledge, setAcknowledge] = useState(false);
  const [warning, setWarning] = useState("");
  const [fields, setFields] = useState({
    name: String(initial?.name ?? ""),
    generic_name: String(initial?.generic_name ?? ""),
    brand_name: String(initial?.brand_name ?? ""),
    manufacturer: String(initial?.manufacturer ?? ""),
    strength: String(initial?.strength ?? ""),
    dosage_form: String(initial?.dosage_form || "tablet"),
    composition: String(initial?.composition ?? ""),
    hsn_code: String(initial?.hsn_code ?? ""),
    schedule_category: String(initial?.schedule_category || "OTC"),
  });

  function setField(key: keyof typeof fields, value: string) {
    setFields((current) => ({ ...current, [key]: value }));
  }

  async function lookup() {
    if (fields.name.trim().length < 2) {
      toast.error("Enter the medicine name first.");
      return;
    }
    setLooking(true);
    const result = await lookupMedicine(fields.name.trim());
    setLooking(false);
    if (!result.ok) {
      toast.error(result.message);
      return;
    }
    setFields((current) => ({
      name: current.name || result.data.name,
      generic_name: result.data.generic_name || current.generic_name,
      brand_name: current.brand_name || result.data.brand_name,
      manufacturer: current.manufacturer || result.data.manufacturer,
      strength: current.strength || result.data.strength,
      dosage_form: result.data.dosage_form || current.dosage_form,
      composition: result.data.composition || current.composition,
      hsn_code: current.hsn_code || result.data.hsn_code,
      schedule_category: result.data.schedule_category || current.schedule_category,
    }));
    toast.success("Contents filled. Check them against the pack before saving.");
  }

  async function onSubmit(formData: FormData) {
    setPending(true);
    const result = await saveMedicine({
      id: initial?.id || undefined,
      medicine_code: String(formData.get("medicine_code") ?? ""),
      name: formData.get("name"),
      generic_name: formData.get("generic_name"),
      brand_name: formData.get("brand_name"),
      manufacturer: formData.get("manufacturer"),
      composition: formData.get("composition"),
      strength: formData.get("strength"),
      dosage_form: formData.get("dosage_form"),
      pack_size: formData.get("pack_size"),
      unit_of_measure: formData.get("unit_of_measure"),
      hsn_code: formData.get("hsn_code"),
      gst_rate: formData.get("gst_rate"),
      tax_classification: formData.get("tax_classification"),
      barcode: formData.get("barcode"),
      schedule_category: formData.get("schedule_category"),
      prescription_required: formData.get("prescription_required") === "on",
      mrp: formData.get("mrp"),
      default_selling_price: formData.get("default_selling_price"),
      reorder_level: formData.get("reorder_level"),
      is_active: formData.get("is_active") !== "off",
      acknowledge_duplicate: acknowledge,
    });
    setPending(false);
    if (!result.ok) {
      setWarning(result.message);
      toast.error(result.message);
      return;
    }
    toast.success("Medicine saved");
    router.push("/medicines");
    router.refresh();
  }

  const value = (key: string) => (initial?.[key] ?? "") as string | number;

  return (
    <form action={onSubmit} className="grid gap-4 rounded-2xl border bg-white p-5 md:grid-cols-2">
      <Field label="Medicine name">
        <div className="flex gap-2">
          <Input name="name" required value={fields.name} onChange={(event) => setField("name", event.target.value)} />
          <Button type="button" variant="secondary" disabled={looking} onClick={() => void lookup()}>{looking ? "Searching..." : "Look up contents"}</Button>
        </div>
      </Field>
      <Field label="Code"><Input name="medicine_code" defaultValue={value("medicine_code")} placeholder="Leave blank to generate" /></Field>
      <Field label="Generic / salt"><Input name="generic_name" value={fields.generic_name} onChange={(event) => setField("generic_name", event.target.value)} /></Field>
      <Field label="Brand"><Input name="brand_name" value={fields.brand_name} onChange={(event) => setField("brand_name", event.target.value)} /></Field>
      <Field label="Strength"><Input name="strength" value={fields.strength} onChange={(event) => setField("strength", event.target.value)} placeholder="500 mg" /></Field>
      <Field label="Dosage form">
        <Select name="dosage_form" value={fields.dosage_form} onChange={(event) => setField("dosage_form", event.target.value)}>
          {DOSAGE_FORMS.map((form) => <option key={form}>{form}</option>)}
        </Select>
      </Field>
      <Field label="Pack size"><Input name="pack_size" defaultValue={value("pack_size")} /></Field>
      <Field label="Manufacturer"><Input name="manufacturer" value={fields.manufacturer} onChange={(event) => setField("manufacturer", event.target.value)} /></Field>
      <Field label="HSN"><Input name="hsn_code" value={fields.hsn_code} onChange={(event) => setField("hsn_code", event.target.value)} /></Field>
      <Field label="Barcode"><Input name="barcode" defaultValue={value("barcode")} /></Field>
      <Field label="GST rate %"><Input name="gst_rate" defaultValue={value("gst_rate") || "5"} /></Field>
      <Field label="Tax classification">
        <Select name="tax_classification" defaultValue={String(value("tax_classification") || "taxable")}>
          <option value="taxable">Taxable</option>
          <option value="exempt">Exempt</option>
          <option value="nil">Nil</option>
          <option value="zero">Zero rated</option>
        </Select>
      </Field>
      <Field label="Schedule">
        <Select name="schedule_category" value={fields.schedule_category} onChange={(event) => setField("schedule_category", event.target.value)}>
          {SCHEDULES.map((schedule) => <option key={schedule}>{schedule}</option>)}
        </Select>
      </Field>
      <Field label="MRP"><Input name="mrp" defaultValue={value("mrp") || "0"} /></Field>
      <Field label="Default selling price"><Input name="default_selling_price" defaultValue={value("default_selling_price") || "0"} /></Field>
      <Field label="Reorder level"><Input name="reorder_level" defaultValue={value("reorder_level") || "0"} /></Field>
      <Field label="Unit"><Input name="unit_of_measure" defaultValue={value("unit_of_measure") || "pack"} /></Field>
      <div className="md:col-span-2">
        <Field label="Composition" hint="Look up contents searches published product information. Compare the salt and strength with the pack before saving.">
          <Textarea name="composition" value={fields.composition} onChange={(event) => setField("composition", event.target.value)} />
        </Field>
      </div>
      <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="prescription_required" defaultChecked={Boolean(initial?.prescription_required)} /> Prescription required</label>
      <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={acknowledge} onChange={(event) => setAcknowledge(event.target.checked)} /> Save even if an exact duplicate is found</label>
      {warning ? <p className="md:col-span-2 text-sm text-amber-800">{warning}</p> : null}
      <div className="md:col-span-2"><Button disabled={pending}>{pending ? "Saving..." : "Save medicine"}</Button></div>
    </form>
  );
}
