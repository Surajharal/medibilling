import Decimal from "decimal.js";
import { D, costStr, money } from "@/lib/money";

/**
 * Estimated batch cost per saleable pack.
 * Free quantity is included in the denominator.
 * For a GST-registered pharmacy, GST is excluded because it is treated as input tax credit.
 * For a pharmacy that is not GST-registered, GST is included in the cost.
 * This cost is a gross-margin basis only. It is not net profit.
 */
export function batchUnitCost(input: {
  paidQty: string;
  freeQty: string;
  purchaseRate: string;
  discountAmount: string;
  gstAmount: string;
  gstRegistered: boolean;
}): string {
  const totalQty = D(input.paidQty).plus(input.freeQty);
  if (totalQty.lte(0)) throw new Error("quantity_required");
  const gross = money(D(input.paidQty).mul(input.purchaseRate));
  const taxable = gross.minus(money(input.discountAmount));
  if (taxable.lt(0)) throw new Error("discount_exceeds_gross");
  const costBase = input.gstRegistered ? taxable : taxable.plus(money(input.gstAmount));
  return costStr(costBase.div(totalQty));
}

export function weightedAverageCost(
  oldQty: string,
  oldCost: string,
  addQty: string,
  addCost: string,
): string {
  const nextQty = D(oldQty).plus(addQty);
  if (nextQty.lte(0)) throw new Error("quantity_required");
  if (D(oldQty).lte(0)) return costStr(addCost);
  const total = D(oldQty).mul(oldCost).plus(D(addQty).mul(addCost));
  return costStr(total.div(nextQty));
}

/** Estimated gross profit for one sold line. Not net profit. */
export function estimatedGrossProfit(taxableValue: string, unitCost: string, quantityInPacks: string): string {
  return D(taxableValue)
    .minus(D(unitCost).mul(quantityInPacks))
    .toDecimalPlaces(2, Decimal.ROUND_HALF_UP)
    .toFixed(2);
}
