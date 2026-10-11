import Decimal from "decimal.js";
import { D, money, moneyStr } from "@/lib/money";

/**
 * Rounding and tax policy (authoritative copy also implemented in SQL
 * `calculate_invoice_totals`):
 *
 * 1. Currency is Indian Rupees stored to 2 decimal places (paise).
 * 2. Round half up (PostgreSQL `round(numeric, scale)` for positive amounts).
 * 3. Line gross = round(quantity × unit price, 2).
 * 4. A line discount is either a percent of gross or an absolute amount.
 * 5. The bill discount is allocated across lines in proportion to
 *    (gross − line discount). Earlier lines are rounded independently.
 *    The last line receives the remainder so shares sum to the bill discount.
 * 6. GST-exclusive: taxable value is the net amount after discounts.
 *    GST = round(taxable × rate / 100, 2). Line total = taxable + GST.
 * 7. GST-inclusive: the net amount already includes GST.
 *    Taxable = round(net / (1 + rate / 100), 2). GST = net − taxable.
 * 8. Exempt, nil, and zero classifications, and a 0% rate, produce no GST.
 *    The net amount is the taxable value and the line total.
 * 9. Intra-state supply splits GST into CGST and SGST. CGST is round(GST / 2, 2)
 *    and SGST is the remainder, so CGST + SGST = GST.
 * 10. Inter-state supply puts the full GST amount in IGST.
 * 11. Optional cash rounding moves only the invoice total to the nearest rupee.
 *    The round-off is not tax. Line tax snapshots stay at paise.
 * 12. Historical invoices store these snapshots and are not recalculated later.
 */

export type PricingMode = "inclusive" | "exclusive";
export type TaxClassification = "taxable" | "exempt" | "nil" | "zero";
export type SupplyType = "intra" | "inter";

export interface LineInput {
  quantity: string;
  unitPrice: string;
  discountAmount?: string | null;
  discountPercent?: string | null;
  gstRate: string;
  taxClassification: TaxClassification;
}

export interface InvoiceInput {
  pricingMode: PricingMode;
  supplyType: SupplyType;
  billDiscountAmount?: string | null;
  roundToRupee?: boolean;
  lines: LineInput[];
}

export interface LineResult {
  gross: string;
  discount: string;
  billDiscountShare: string;
  taxableValue: string;
  gstRate: string;
  cgst: string;
  sgst: string;
  igst: string;
  gstAmount: string;
  lineTotal: string;
}

export interface InvoiceResult {
  lines: LineResult[];
  gross: string;
  discountTotal: string;
  taxableValue: string;
  cgst: string;
  sgst: string;
  igst: string;
  gstAmount: string;
  roundOff: string;
  grandTotal: string;
}

export class InvoiceCalculationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "InvoiceCalculationError";
  }
}

export function supplyTypeForCustomer(
  pharmacyStateCode: string,
  customerGstin?: string | null,
): SupplyType {
  const gstin = (customerGstin ?? "").trim().toUpperCase();
  if (gstin.length < 2) return "intra";
  return gstin.slice(0, 2) === pharmacyStateCode ? "intra" : "inter";
}

export function splitGst(gstAmount: Decimal, supplyType: SupplyType) {
  const gst = money(gstAmount);
  if (supplyType === "inter") {
    return { cgst: money(0), sgst: money(0), igst: gst };
  }
  const cgst = money(gst.div(2));
  const sgst = gst.minus(cgst);
  return { cgst, sgst, igst: money(0) };
}

function lineDiscount(gross: Decimal, line: LineInput): Decimal {
  const percent = line.discountPercent?.trim();
  const amount = line.discountAmount?.trim();
  if (percent && amount && D(amount).gt(0) && D(percent).gt(0)) {
    throw new InvoiceCalculationError("discount_conflict");
  }
  const discount = percent ? money(gross.mul(D(percent)).div(100)) : money(amount || 0);
  if (discount.lt(0) || discount.gt(gross)) {
    throw new InvoiceCalculationError("discount_exceeds_gross");
  }
  return discount;
}

export function calculateInvoice(input: InvoiceInput): InvoiceResult {
  if (input.lines.length === 0) {
    throw new InvoiceCalculationError("lines_required");
  }

  const prepared = input.lines.map((line) => {
    const quantity = D(line.quantity);
    const unitPrice = D(line.unitPrice);
    if (quantity.lte(0) || unitPrice.lt(0)) {
      throw new InvoiceCalculationError("invalid_line");
    }
    const gross = money(quantity.mul(unitPrice));
    const discount = lineDiscount(gross, line);
    return {
      line,
      gross,
      discount,
      base: gross.minus(discount),
      rate: D(line.gstRate),
    };
  });

  const baseSum = prepared.reduce((sum, line) => sum.plus(line.base), D(0));
  const billDiscount = money(input.billDiscountAmount || 0);
  if (billDiscount.lt(0) || billDiscount.gt(baseSum)) {
    throw new InvoiceCalculationError("bill_discount_exceeds_total");
  }

  let allocated = D(0);
  const shares = prepared.map((line, index) => {
    if (index === prepared.length - 1) return billDiscount.minus(allocated);
    const share = baseSum.eq(0) ? money(0) : money(billDiscount.mul(line.base).div(baseSum));
    allocated = allocated.plus(share);
    return share;
  });

  const lines: LineResult[] = prepared.map((line, index) => {
    const share = shares[index];
    if (share.lt(0) || share.gt(line.base)) {
      throw new InvoiceCalculationError("bill_discount_allocation_failed");
    }
    const net = line.base.minus(share);
    const chargesGst = line.line.taxClassification === "taxable" && line.rate.gt(0);
    let taxable: Decimal;
    let gst: Decimal;
    if (!chargesGst) {
      taxable = net;
      gst = money(0);
    } else if (input.pricingMode === "exclusive") {
      taxable = net;
      gst = money(taxable.mul(line.rate).div(100));
    } else {
      taxable = money(net.div(D(1).plus(line.rate.div(100))));
      gst = net.minus(taxable);
    }
    const parts = splitGst(gst, input.supplyType);
    const lineTotal = taxable.plus(gst);
    return {
      gross: moneyStr(line.gross),
      discount: moneyStr(line.discount),
      billDiscountShare: moneyStr(share),
      taxableValue: moneyStr(taxable),
      gstRate: moneyStr(line.rate),
      cgst: moneyStr(parts.cgst),
      sgst: moneyStr(parts.sgst),
      igst: moneyStr(parts.igst),
      gstAmount: moneyStr(gst),
      lineTotal: moneyStr(lineTotal),
    };
  });

  const sum = (key: keyof LineResult) =>
    lines.reduce((total, line) => total.plus(line[key]), D(0));

  const exact = sum("lineTotal");
  const rounded = input.roundToRupee ? exact.toDecimalPlaces(0, Decimal.ROUND_HALF_UP) : exact;
  const roundOff = rounded.minus(exact);

  return {
    lines,
    gross: moneyStr(sum("gross")),
    discountTotal: moneyStr(sum("discount").plus(billDiscount)),
    taxableValue: moneyStr(sum("taxableValue")),
    cgst: moneyStr(sum("cgst")),
    sgst: moneyStr(sum("sgst")),
    igst: moneyStr(sum("igst")),
    gstAmount: moneyStr(sum("gstAmount")),
    roundOff: moneyStr(roundOff),
    grandTotal: moneyStr(rounded),
  };
}

export function effectiveDiscountPercent(gross: string, discount: string, billShare: string): Decimal {
  const base = D(gross);
  if (base.eq(0)) return D(0);
  return D(discount).plus(billShare).div(base).mul(100);
}
