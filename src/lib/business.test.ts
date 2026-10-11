import { describe, expect, it } from "vitest";
import { financialYearLabel, invoiceNumber } from "@/lib/fy";
import { can } from "@/lib/permissions";
import { validatePayments } from "@/lib/payments";
import { returnLineAmounts } from "@/lib/returns";

describe("financial year and invoice numbers", () => {
  it("uses April as the default year boundary", () => {
    expect(financialYearLabel("2026-04-01", 4)).toBe("2026-27");
    expect(financialYearLabel("2026-03-31", 4)).toBe("2025-26");
  });

  it("formats a unique sequential invoice number", () => {
    expect(invoiceNumber("MB", "2026-27", 42)).toBe("MB/2026-27/000042");
  });
});

describe("authorization", () => {
  it("keeps billing operators away from settings, profit, and stock changes", () => {
    expect(can("billing_operator", "billing.create")).toBe(true);
    expect(can("billing_operator", "settings.manage")).toBe(false);
    expect(can("billing_operator", "reports.profit")).toBe(false);
    expect(can("billing_operator", "inventory.adjust")).toBe(false);
    expect(can("billing_operator", "purchases.manage")).toBe(false);
  });

  it("lets a pharmacist operate the shop without owner settings", () => {
    expect(can("pharmacist", "returns.manage")).toBe(true);
    expect(can("pharmacist", "users.manage")).toBe(false);
    expect(can("pharmacist", "audit.view")).toBe(false);
  });

  it("gives the owner every action", () => {
    expect(can("owner", "settings.manage")).toBe(true);
    expect(can("owner", "audit.view")).toBe(true);
  });
});

describe("payments", () => {
  it("accepts a split tender and calculates change", () => {
    const result = validatePayments({
      grandTotal: "100.00",
      payments: [
        { method: "cash", amount: "40.00" },
        { method: "upi", amount: "60.00" },
      ],
      allowCredit: false,
      hasCustomer: false,
      creditLimit: "0",
      currentOutstanding: "0",
      amountTendered: "50.00",
    });
    expect(result).toEqual({ amountPaid: "100.00", balanceDue: "0.00", changeDue: "10.00" });
  });

  it("rejects an unbalanced or unauthorized credit sale", () => {
    expect(() =>
      validatePayments({
        grandTotal: "100.00",
        payments: [{ method: "cash", amount: "90.00" }],
        allowCredit: true,
        hasCustomer: true,
        creditLimit: "500",
        currentOutstanding: "0",
      }),
    ).toThrow("payment_mismatch");

    expect(() =>
      validatePayments({
        grandTotal: "100.00",
        payments: [{ method: "credit", amount: "100.00" }],
        allowCredit: false,
        hasCustomer: true,
        creditLimit: "500",
        currentOutstanding: "0",
      }),
    ).toThrow("credit_not_allowed");
  });

  it("enforces the credit limit", () => {
    expect(() =>
      validatePayments({
        grandTotal: "80.00",
        payments: [{ method: "credit", amount: "80.00" }],
        allowCredit: true,
        hasCustomer: true,
        creditLimit: "100.00",
        currentOutstanding: "30.00",
      }),
    ).toThrow("credit_limit_exceeded");
  });
});

describe("returns", () => {
  it("limits a return to the unsold remainder and keeps the final paise", () => {
    const first = returnLineAmounts(
      {
        quantity: "3",
        alreadyReturned: "0",
        taxableValue: "10.00",
        gstAmount: "1.00",
        discount: "0.00",
        lineTotal: "11.00",
        alreadyReturnedTaxable: "0",
        alreadyReturnedGst: "0",
        alreadyReturnedDiscount: "0",
        alreadyReturnedTotal: "0",
      },
      "1",
    );
    expect(first.lineTotal).toBe("3.67");
    expect(() =>
      returnLineAmounts(
        {
          quantity: "2",
          alreadyReturned: "2",
          taxableValue: "20",
          gstAmount: "0",
          discount: "0",
          lineTotal: "20",
          alreadyReturnedTaxable: "20",
          alreadyReturnedGst: "0",
          alreadyReturnedDiscount: "0",
          alreadyReturnedTotal: "20",
        },
        "1",
      ),
    ).toThrow("return_qty_exceeded");

    const closing = returnLineAmounts(
      {
        quantity: "3",
        alreadyReturned: "2",
        taxableValue: "10.00",
        gstAmount: "0.00",
        discount: "0.00",
        lineTotal: "10.00",
        alreadyReturnedTaxable: "6.67",
        alreadyReturnedGst: "0",
        alreadyReturnedDiscount: "0",
        alreadyReturnedTotal: "6.67",
      },
      "1",
    );
    expect(closing.lineTotal).toBe("3.33");
  });
});
