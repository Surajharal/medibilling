import Decimal from "decimal.js";

Decimal.set({ precision: 40, rounding: Decimal.ROUND_HALF_UP });

/** Half-up rounding for positive pharmacy amounts. Matches PostgreSQL round(numeric, scale). */
export function D(value: Decimal.Value): Decimal {
  return new Decimal(value);
}

export function money(value: Decimal.Value): Decimal {
  return D(value).toDecimalPlaces(2, Decimal.ROUND_HALF_UP);
}

export function moneyStr(value: Decimal.Value): string {
  return money(value).toFixed(2);
}

export function qtyStr(value: Decimal.Value): string {
  return D(value).toDecimalPlaces(3, Decimal.ROUND_HALF_UP).toFixed(3);
}

export function costStr(value: Decimal.Value): string {
  return D(value).toDecimalPlaces(4, Decimal.ROUND_HALF_UP).toFixed(4);
}

export function isPositiveDecimal(value: string): boolean {
  try {
    return D(value).gt(0);
  } catch {
    return false;
  }
}
