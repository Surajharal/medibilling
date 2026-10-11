import { BillingScreen } from "@/components/billing-screen";
import { can } from "@/lib/permissions";
import { requireAction } from "@/lib/tenant";

export default async function BillingPage() {
  const context = await requireAction("billing.create");
  return (
    <BillingScreen
      pricingMode={context.pharmacy.pricing_mode}
      allowCredit={context.pharmacy.allow_credit_sales}
      defaultMethod={context.pharmacy.default_payment_method}
      canOverridePrice={can(context.role, "price.override")}
    />
  );
}
