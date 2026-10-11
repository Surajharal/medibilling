"use client";

import { useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { importMedicines } from "@/server/operations";

export function ImportForm() {
  const [report, setReport] = useState<{ imported: number; errors: { row: number; message: string }[] } | null>(null);
  async function onSubmit(formData: FormData) {
    const file = formData.get("file");
    if (!(file instanceof File)) return;
    const text = await file.text();
    const result = await importMedicines(text);
    setReport({ imported: result.imported, errors: result.errors });
    if (result.errors.length > 0) toast.error(`${result.errors.length} rows were skipped.`);
    else toast.success(`${result.imported} medicines imported.`);
  }
  return (
    <form action={onSubmit} className="space-y-4">
      <input name="file" type="file" accept=".csv,text/csv" required />
      <Button>Import</Button>
      <p className="text-xs text-slate-500">Columns: name, generic_name, brand_name, strength, dosage_form, pack_size, manufacturer, hsn_code, gst_rate, tax_classification, barcode, schedule_category, prescription_required, mrp, default_selling_price, reorder_level, medicine_code.</p>
      {report ? (
        <div className="text-sm">
          <p>{report.imported} rows saved.</p>
          {report.errors.map((error) => <p key={error.row}>Row {error.row}: {error.message}</p>)}
        </div>
      ) : null}
    </form>
  );
}
