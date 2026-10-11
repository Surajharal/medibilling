import { describe, expect, it } from "vitest";
import {
  isSaleableBatch,
  medicineExpiryState,
  selectFefo,
  isLowStock,
  isOutOfStock,
} from "@/lib/inventory/fefo";
import { batchUnitCost, estimatedGrossProfit, weightedAverageCost } from "@/lib/inventory/valuation";

const batches = [
  { id: "later", expiryDate: "2027-06-01", qtyAvailable: "5", status: "active", createdAt: "2026-01-01" },
  { id: "soon", expiryDate: "2026-12-01", qtyAvailable: "2", status: "active", createdAt: "2026-02-01" },
  { id: "expired", expiryDate: "2026-01-01", qtyAvailable: "9", status: "active", createdAt: "2025-01-01" },
  { id: "blocked", expiryDate: "2026-11-01", qtyAvailable: "4", status: "quarantined", createdAt: "2026-01-01" },
  { id: "empty", expiryDate: "2026-10-01", qtyAvailable: "0", status: "active", createdAt: "2026-01-01" },
];

describe("batch selection and stock alerts", () => {
  it("selects the earliest eligible expiry", () => {
    expect(selectFefo(batches, "2026-10-10")?.id).toBe("soon");
  });

  it("does not sell expired, quarantined, or empty batches", () => {
    expect(isSaleableBatch(batches[2], "2026-10-10")).toBe(false);
    expect(isSaleableBatch(batches[3], "2026-10-10")).toBe(false);
    expect(isSaleableBatch(batches[4], "2026-10-10")).toBe(false);
    expect(selectFefo([batches[2], batches[3], batches[4]], "2026-10-10")).toBeNull();
  });

  it("allows sale on the expiry date", () => {
    expect(
      isSaleableBatch(
        { id: "today", expiryDate: "2026-10-10", qtyAvailable: "1", status: "active", createdAt: "2026-01-01" },
        "2026-10-10",
      ),
    ).toBe(true);
  });

  it("does not treat a medicine as expired when another batch is saleable", () => {
    expect(
      medicineExpiryState(
        [
          { expiryDate: "2026-01-01", qtyAvailable: "3", status: "active" },
          { expiryDate: "2027-01-01", qtyAvailable: "8", status: "active" },
        ],
        "2026-10-10",
      ),
    ).toBe("partial");
  });

  it("flags low and out-of-stock quantities", () => {
    expect(isLowStock("4", "5", "10")).toBe(true);
    expect(isLowStock("6", "5", "10")).toBe(false);
    expect(isLowStock("10", "0", "10")).toBe(true);
    expect(isOutOfStock("0")).toBe(true);
  });
});

describe("stock valuation", () => {
  it("spreads free quantity into the GST-registered cost and excludes GST", () => {
    expect(
      batchUnitCost({
        paidQty: "10",
        freeQty: "2",
        purchaseRate: "100",
        discountAmount: "0",
        gstAmount: "120",
        gstRegistered: true,
      }),
    ).toBe("83.3333");
  });

  it("includes GST in cost when the pharmacy is not registered", () => {
    expect(
      batchUnitCost({
        paidQty: "10",
        freeQty: "0",
        purchaseRate: "100",
        discountAmount: "0",
        gstAmount: "12",
        gstRegistered: false,
      }),
    ).toBe("101.2000");
  });

  it("uses a weighted average when the same batch is received again", () => {
    expect(weightedAverageCost("10", "80", "10", "100")).toBe("90.0000");
  });

  it("estimates gross profit from taxable value and batch cost", () => {
    expect(estimatedGrossProfit("100.00", "80.0000", "1")).toBe("20.00");
  });
});
