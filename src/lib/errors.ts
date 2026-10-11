const MESSAGES: Record<string, string> = {
  not_authenticated: "Please sign in again.",
  not_authorized: "You do not have permission to do that.",
  insufficient_stock: "Not enough stock is available in the selected batch.",
  batch_not_saleable: "This batch is expired, blocked, or not saleable.",
  near_expiry_acknowledgement_required: "Confirm the near-expiry warning before completing this bill.",
  duplicate_supplier_invoice: "This supplier invoice number is already posted. An owner can record an authorised override.",
  credit_not_allowed: "Credit is not enabled for this sale or customer.",
  credit_limit_exceeded: "This would exceed the customer's credit limit.",
  prescription_role_required: "A pharmacist or owner must complete bills that include prescription medicines.",
  price_above_mrp: "The selling price cannot be above MRP.",
  price_override_not_allowed: "Billing operators must use the batch selling price. Ask a pharmacist to change it.",
  discount_not_permitted: "This discount is above your permitted limit.",
  payment_mismatch: "The payments do not add up to the invoice total.",
  payment_required: "Add a payment before completing the bill.",
  payment_amount_invalid: "Enter an amount greater than zero that is not above the amount due.",
  lines_required: "Add at least one line before posting.",
  invoice_line_not_found: "That bill line could not be found.",
  idempotency_key_required: "The request could not be repeated safely. Try again.",
  balance_change_forbidden: "That balance can only change through a posted bill, purchase, receipt, or payment.",
  invalid_purchase_line: "Check the purchase line. Quantity must be above zero, and the selling price cannot be above MRP.",
  insufficient_tender: "The cash received is less than the cash payment.",
  rate_limited: "Too many attempts. Wait a moment and try again.",
  return_qty_exceeded: "The return quantity is higher than the quantity still returnable.",
  refund_exceeds_paid: "The refund is higher than the amount paid or the balance still due.",
  negative_stock_not_allowed: "Stock cannot go below zero.",
  batch_not_receivable: "That batch is blocked and cannot receive more stock.",
  medicine_not_found: "One of the medicines could not be found.",
  batch_not_found: "One of the batches could not be found.",
  customer_not_found: "The customer could not be found.",
  supplier_not_found: "The supplier could not be found.",
  invoice_not_found: "The invoice could not be found.",
  posted_invoice_immutable: "Posted invoices cannot be edited.",
  posted_document_immutable: "Posted records cannot be changed.",
  duplicate_medicine_code: "That medicine code is already in use.",
  reason_required: "A reason is required.",
  expiry_required: "Enter the batch expiry date.",
  invalid_date_range: "Choose a valid date range of up to 400 days.",
  unknown_report: "That report is not available.",
  receipt_exceeds_outstanding: "The receipt is higher than the outstanding balance.",
  balance_credit_exceeds_due: "The balance credit is higher than the customer's outstanding balance.",
};

export function mapDbError(error: { message?: string } | null | undefined): string {
  const message = error?.message ?? "";
  for (const [key, text] of Object.entries(MESSAGES)) {
    if (message.includes(key)) return text;
  }
  if (message.includes("medicines_barcode_unique")) return "That barcode is already used by another medicine.";
  if (message.includes("medicines_pharmacy_id_medicine_code_key")) return "That medicine code is already in use.";
  if (message.includes("customers_phone_unique")) return "A customer with this phone number already exists.";
  if (message.includes("invalid input syntax for type date")) return "Enter the batch expiry date.";
  if (message.includes("invalid input syntax for type numeric")) return "Enter the rate, MRP, and selling price as numbers.";
  if (message.includes("Could not find the function")) {
    return "That action is not installed in the database yet. In the Supabase SQL Editor, run the latest file in supabase/migrations, then try again.";
  }
  if (message.includes("batch_number")) return "Enter a batch number.";
  if (/password|token|secret|service_role|api[_ ]key/i.test(message)) {
    return "The request could not be completed.";
  }
  return "The record could not be saved. Check the details and try again.";
}
