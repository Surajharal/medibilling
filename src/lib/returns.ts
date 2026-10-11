import Decimal from "decimal.js";
import { D, money, moneyStr } from "@/lib/money";

export interface ReturnLineSource {
  quantity: string;
  alreadyReturned: string;
  taxableValue: string;
  gstAmount: string;
  discount: string;
  lineTotal: string;
  alreadyReturnedTaxable: string;
  alreadyReturnedGst: string;
  alreadyReturnedDiscount: string;
  alreadyReturnedTotal: string;
}

export interface ReturnLineAmounts {
  quantity: string;
  taxableValue: string;
  gstAmount: string;
  discount: string;
  lineTotal: string;
}

/**
 * Return amounts use the original invoice snapshots.
 * A final return of a line takes the unreturned remainder so paise are not lost or duplicated.
 */
export function returnLineAmounts(source: ReturnLineSource, quantity: string): ReturnLineAmounts {
  const originalQty = D(source.quantity);
  const already = D(source.alreadyReturned);
  const requested = D(quantity);
  if (requested.lte(0)) throw new Error("return_qty_invalid");
  const remaining = originalQty.minus(already);
  if (requested.gt(remaining)) throw new Error("return_qty_exceeded");
  const closesLine = requested.eq(remaining);
  const take = (original: string, alreadyAmount: string) => {
    if (closesLine) return money(D(original).minus(alreadyAmount));
    return money(D(original).mul(requested).div(originalQty));
  };
  return {
    quantity: requested.toDecimalPlaces(3, Decimal.ROUND_HALF_UP).toFixed(3),
    taxableValue: moneyStr(take(source.taxableValue, source.alreadyReturnedTaxable)),
    gstAmount: moneyStr(take(source.gstAmount, source.alreadyReturnedGst)),
    discount: moneyStr(take(source.discount, source.alreadyReturnedDiscount)),
    lineTotal: moneyStr(take(source.lineTotal, source.alreadyReturnedTotal)),
  };
}
