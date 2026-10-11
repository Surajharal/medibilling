import { D, money, moneyStr } from "@/lib/money";

export const PAYMENT_METHODS = ["cash", "upi", "card", "bank_transfer", "credit"] as const;
export type PaymentMethod = (typeof PAYMENT_METHODS)[number];

export interface PaymentInput {
  method: PaymentMethod;
  amount: string;
  reference?: string;
}

export interface PaymentValidation {
  amountPaid: string;
  balanceDue: string;
  changeDue: string;
}

export function validatePayments(input: {
  grandTotal: string;
  payments: PaymentInput[];
  allowCredit: boolean;
  hasCustomer: boolean;
  creditLimit: string;
  currentOutstanding: string;
  amountTendered?: string | null;
}): PaymentValidation {
  if (input.payments.length === 0) throw new Error("payment_required");
  const total = money(input.grandTotal);
  let paid = D(0);
  let credit = D(0);
  let cash = D(0);
  for (const payment of input.payments) {
    const amount = money(payment.amount);
    if (amount.lte(0)) throw new Error("payment_amount_invalid");
    if (!PAYMENT_METHODS.includes(payment.method)) throw new Error("payment_method_invalid");
    if (payment.method === "credit") credit = credit.plus(amount);
    else paid = paid.plus(amount);
    if (payment.method === "cash") cash = cash.plus(amount);
  }
  if (!paid.plus(credit).eq(total)) throw new Error("payment_mismatch");
  if (credit.gt(0)) {
    if (!input.allowCredit || !input.hasCustomer) throw new Error("credit_not_allowed");
    const limit = D(input.creditLimit || 0);
    if (limit.lte(0) || D(input.currentOutstanding || 0).plus(credit).gt(limit)) {
      throw new Error("credit_limit_exceeded");
    }
  }
  const tendered = money(input.amountTendered || 0);
  if (cash.gt(0) && tendered.lt(cash)) throw new Error("insufficient_tender");
  const change = cash.gt(0) ? tendered.minus(cash) : money(0);
  return {
    amountPaid: moneyStr(paid),
    balanceDue: moneyStr(credit),
    changeDue: moneyStr(change),
  };
}
