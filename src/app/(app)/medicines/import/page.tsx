import { ImportForm } from "@/components/import-form";
import { PageHeader } from "@/components/page-header";
import { requireAction } from "@/lib/tenant";

export default async function ImportPage() {
  await requireAction("medicines.manage");
  return (
    <div>
      <PageHeader title="Import medicines" description="Invalid rows are reported and are not saved. Duplicate exact medicines are skipped." />
      <ImportForm />
    </div>
  );
}
