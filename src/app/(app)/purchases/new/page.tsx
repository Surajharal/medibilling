import { PurchaseForm } from "@/components/purchase-form";
import { PageHeader } from "@/components/page-header";
import { requireAction } from "@/lib/tenant";

export default async function NewPurchasePage() {
  const context = await requireAction("purchases.manage");
  const { data: suppliers } = await context.supabase.from("suppliers").select("id, name").eq("pharmacy_id", context.pharmacy.id).eq("is_active", true).order("name");
  const { data: medicines } = await context.supabase.from("medicines").select("id, name, strength, gst_rate").eq("pharmacy_id", context.pharmacy.id).eq("is_active", true).order("name").limit(500);
  return (
    <div>
      <PageHeader title="Post a purchase" description="Purchase prices are GST exclusive. Free quantity increases stock and reduces the unit cost." />
      {(suppliers ?? []).length === 0 || (medicines ?? []).length === 0 ? <p>Add a supplier and a medicine before posting a purchase.</p> : <PurchaseForm suppliers={suppliers ?? []} medicines={medicines ?? []} />}
    </div>
  );
}
