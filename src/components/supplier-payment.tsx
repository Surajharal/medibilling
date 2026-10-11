"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Field, Input } from "@/components/ui/inputs";
import { recordSupplierPayment } from "@/server/operations";

export function SupplierPayment({ supplierId }: { supplierId: string }) {
  const router = useRouter();
  const [pending, setPending] = useState(false);
  async function onSubmit(formData: FormData) {
    setPending(true);
    const result = await recordSupplierPayment({ supplier_id: supplierId, amount: formData.get("amount"), notes: formData.get("notes") });
    setPending(false);
    if (!result.ok) toast.error(result.message);
    else {
      toast.success("Payment recorded");
      router.refresh();
    }
  }
  return (
    <form action={onSubmit} className="mt-4 flex max-w-md gap-2">
      <Field label="Payment amount"><Input name="amount" required /></Field>
      <div className="self-end"><Button disabled={pending}>Record payment</Button></div>
    </form>
  );
}
