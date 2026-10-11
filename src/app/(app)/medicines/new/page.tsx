import { MedicineForm } from "@/components/medicine-form";
import { PageHeader } from "@/components/page-header";
import { requireAction } from "@/lib/tenant";

export default async function NewMedicinePage() {
  await requireAction("medicines.manage");
  return (
    <div>
      <PageHeader title="Add medicine" description="Similar names with a different strength or pack are kept separate." />
      <MedicineForm />
    </div>
  );
}
