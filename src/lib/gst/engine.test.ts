import { describe, expect, it } from "vitest";
import { calculateInvoice, supplyTypeForCustomer } from "@/lib/gst/engine";

function baseLine(overrides: Partial<Parameters<typeof calculateInvoice>[0]["lines"][number]> = {}) {
  return {
    quantity: "1",
    unitPrice: "100.00",
    discountAmount: "0",
    gstRate: "18",
    taxClassification: "taxable" as const,
    ...overrides,
  };
}

describe("GST invoice calculation", () => {
  it("calculates an exclusive 18% line as CGST and SGST", () => {
    const result = calculateInvoice({
      pricingMode: "exclusive",
      supplyType: "intra",
      lines: [baseLine()],
    });
    expect(result.lines[0]).toMatchObject({
      taxableValue: "100.00",
      gstAmount: "18.00",
      cgst: "9.00",
      sgst: "9.00",
      igst: "0.00",
      lineTotal: "118.00",
    });
    expect(result.grandTotal).toBe("118.00");
  });

  it("extracts GST from an inclusive price", () => {
    const result = calculateInvoice({
      pricingMode: "inclusive",
      supplyType: "intra",
      lines: [baseLine({ unitPrice: "118.00" })],
    });
    expect(result.lines[0]).toMatchObject({
      taxableValue: "100.00",
      gstAmount: "18.00",
      lineTotal: "118.00",
    });
  });

  it("rounds an inclusive 5% line so tax plus taxable equals the price", () => {
    const result = calculateInvoice({
      pricingMode: "inclusive",
      supplyType: "intra",
      lines: [baseLine({ quantity: "3", unitPrice: "10.00", gstRate: "5" })],
    });
    expect(result.lines[0]).toMatchObject({
      gross: "30.00",
      taxableValue: "28.57",
      gstAmount: "1.43",
      cgst: "0.72",
      sgst: "0.71",
      lineTotal: "30.00",
    });
  });

  it("applies an exclusive line discount before tax", () => {
    const result = calculateInvoice({
      pricingMode: "exclusive",
      supplyType: "intra",
      lines: [baseLine({ quantity: "2", unitPrice: "50.00", discountAmount: "10.00", gstRate: "12" })],
    });
    expect(result.lines[0]).toMatchObject({
      gross: "100.00",
      discount: "10.00",
      taxableValue: "90.00",
      gstAmount: "10.80",
      lineTotal: "100.80",
    });
  });

  it("rounds a percent discount half up", () => {
    const result = calculateInvoice({
      pricingMode: "exclusive",
      supplyType: "intra",
      lines: [baseLine({ unitPrice: "99.99", discountPercent: "10", discountAmount: "0" })],
    });
    expect(result.lines[0].discount).toBe("10.00");
    expect(result.lines[0].taxableValue).toBe("89.99");
    expect(result.lines[0].gstAmount).toBe("16.20");
    expect(result.lines[0].lineTotal).toBe("106.19");
  });

  it("uses IGST for an inter-state supply", () => {
    const result = calculateInvoice({
      pricingMode: "exclusive",
      supplyType: "inter",
      lines: [baseLine({ gstRate: "5" })],
    });
    expect(result.lines[0]).toMatchObject({ igst: "5.00", cgst: "0.00", sgst: "0.00" });
  });

  it("does not tax exempt, nil, or zero-rated lines", () => {
    for (const taxClassification of ["exempt", "nil", "zero"] as const) {
      const result = calculateInvoice({
        pricingMode: "exclusive",
        supplyType: "intra",
        lines: [baseLine({ taxClassification, gstRate: "18" })],
      });
      expect(result.lines[0].gstAmount).toBe("0.00");
      expect(result.lines[0].lineTotal).toBe("100.00");
    }
  });

  it("gives the last line the bill-discount remainder", () => {
    const result = calculateInvoice({
      pricingMode: "exclusive",
      supplyType: "intra",
      billDiscountAmount: "10.00",
      lines: [
        baseLine({ gstRate: "0", taxClassification: "exempt" }),
        baseLine({ unitPrice: "50.00", gstRate: "0", taxClassification: "exempt" }),
      ],
    });
    expect(result.lines.map((line) => line.billDiscountShare)).toEqual(["6.67", "3.33"]);
    expect(result.grandTotal).toBe("140.00");
  });

  it("keeps different GST rates separate and reconciles the invoice", () => {
    const result = calculateInvoice({
      pricingMode: "exclusive",
      supplyType: "intra",
      lines: [
        baseLine({ unitPrice: "100.00", gstRate: "5" }),
        baseLine({ unitPrice: "100.00", gstRate: "12" }),
      ],
    });
    expect(result.taxableValue).toBe("200.00");
    expect(result.gstAmount).toBe("17.00");
    expect(result.grandTotal).toBe("217.00");
    const lineSum = result.lines.reduce((sum, line) => sum + Number(line.lineTotal), 0);
    expect(lineSum.toFixed(2)).toBe("217.00");
  });

  it("rounds only the invoice total to the nearest rupee when requested", () => {
    const result = calculateInvoice({
      pricingMode: "exclusive",
      supplyType: "intra",
      roundToRupee: true,
      lines: [baseLine({ unitPrice: "10.40", gstRate: "5" })],
    });
    expect(result.lines[0].lineTotal).toBe("10.92");
    expect(result.roundOff).toBe("0.08");
    expect(result.grandTotal).toBe("11.00");
  });

  it("rejects a discount larger than the line", () => {
    expect(() =>
      calculateInvoice({
        pricingMode: "inclusive",
        supplyType: "intra",
        lines: [baseLine({ discountAmount: "101.00" })],
      }),
    ).toThrow("discount_exceeds_gross");
  });

  it("selects IGST from a customer GSTIN in another state", () => {
    expect(supplyTypeForCustomer("27", "29ABCDE1234F1Z5")).toBe("inter");
    expect(supplyTypeForCustomer("27", "27ABCDE1234F1Z5")).toBe("intra");
    expect(supplyTypeForCustomer("27", "")).toBe("intra");
  });
});
