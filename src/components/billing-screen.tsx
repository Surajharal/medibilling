"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input, Select } from "@/components/ui/inputs";
import { formatDateOnly, formatINR } from "@/lib/format";
import { completeSale, quoteSale, saveDraft, searchCustomers, searchMedicines, type MedicineHit } from "@/server/operations";

type CartLine = {
  key: string;
  medicineId: string;
  batchId: string;
  name: string;
  strength: string;
  dosageForm: string;
  batchNumber: string;
  expiry: string;
  quantity: string;
  soldUnit: "pack" | "unit";
  unitPrice: string;
  mrp: string;
  discountAmount: string;
  nearExpiry: boolean;
  prescription: boolean;
  schedule: string;
  batches: MedicineHit["batches"];
};

type Quote = {
  totals?: {
    gross: string;
    discount_total: string;
    taxable_value: string;
    cgst: string;
    sgst: string;
    igst: string;
    gst_amount: string;
    round_off: string;
    grand_total: string;
  };
  warnings?: string[];
  prescription_required?: boolean;
  pricing_mode?: string;
  invoice_kind?: string;
};

export function BillingScreen({
  pricingMode,
  allowCredit,
  defaultMethod,
  canOverridePrice,
}: {
  pricingMode: "inclusive" | "exclusive";
  allowCredit: boolean;
  defaultMethod: string;
  canOverridePrice: boolean;
}) {
  const router = useRouter();
  const searchRef = useRef<HTMLInputElement>(null);
  const idempotency = useRef(crypto.randomUUID());
  const lock = useRef(false);
  const [query, setQuery] = useState("");
  const [hits, setHits] = useState<MedicineHit[]>([]);
  const [cart, setCart] = useState<CartLine[]>([]);
  const [customerQuery, setCustomerQuery] = useState("");
  const [customers, setCustomers] = useState<{ id: string; name: string; phone: string; outstanding_balance: string }[]>([]);
  const [customerId, setCustomerId] = useState<string | null>(null);
  const [customerName, setCustomerName] = useState("Walk-in");
  const [billDiscount, setBillDiscount] = useState("0");
  const [ackExpiry, setAckExpiry] = useState(false);
  const [note, setNote] = useState("");
  const [payments, setPayments] = useState<{ method: string; amount: string }[]>([{ method: defaultMethod, amount: "" }]);
  const [tendered, setTendered] = useState("");
  const [quote, setQuote] = useState<Quote | null>(null);
  const [quoteError, setQuoteError] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    const timer = setTimeout(async () => {
      if (query.trim().length < 1) {
        setHits([]);
        return;
      }
      const result = await searchMedicines(query.trim());
      if (result.ok) setHits(result.data ?? []);
    }, 180);
    return () => clearTimeout(timer);
  }, [query]);

  useEffect(() => {
    const timer = setTimeout(async () => {
      if (customerQuery.trim().length < 2) {
        setCustomers([]);
        return;
      }
      const result = await searchCustomers(customerQuery.trim());
      if (result.ok) setCustomers((result.data ?? []) as typeof customers);
    }, 180);
    return () => clearTimeout(timer);
  }, [customerQuery]);

  const payload = useMemo(() => ({
    idempotency_key: idempotency.current,
    customer_id: customerId,
    customer_name: customerName,
    bill_discount_amount: billDiscount || "0",
    acknowledge_near_expiry: ackExpiry,
    prescription_note: note,
    amount_tendered: tendered || "0",
    lines: cart.map((line) => ({
      medicine_id: line.medicineId,
      batch_id: line.batchId,
      quantity: line.quantity,
      sold_unit: line.soldUnit,
      unit_price: line.unitPrice,
      discount_amount: line.discountAmount || "0",
    })),
    payments: payments.filter((payment) => Number(payment.amount) > 0).map((payment) => ({
      method: payment.method,
      amount: payment.amount,
    })),
  }), [ackExpiry, billDiscount, cart, customerId, customerName, note, payments, tendered]);

  useEffect(() => {
    if (cart.length === 0) {
      setQuote(null);
      return;
    }
    const timer = setTimeout(async () => {
      const result = await quoteSale(payload);
      if (!result.ok) {
        setQuoteError(result.message);
        setQuote(null);
        return;
      }
      setQuoteError("");
      setQuote(result.data as Quote);
    }, 250);
    return () => clearTimeout(timer);
  }, [payload, cart.length]);

  function addMedicine(hit: MedicineHit) {
    const batch = hit.batches?.[0];
    if (!batch) {
      toast.error("This medicine has no saleable stock. Post a purchase with a batch and expiry date before billing it.");
      return;
    }
    setCart((current) => [
      ...current,
      {
        key: crypto.randomUUID(),
        medicineId: hit.id,
        batchId: batch.id,
        name: hit.name,
        strength: hit.strength,
        dosageForm: hit.dosage_form,
        batchNumber: batch.batch_number,
        expiry: batch.expiry_date,
        quantity: "1",
        soldUnit: "pack",
        unitPrice: batch.selling_price,
        mrp: batch.mrp,
        discountAmount: "0",
        nearExpiry: batch.near_expiry,
        prescription: hit.prescription_required || ["H", "H1", "X", "G"].includes(hit.schedule_category),
        schedule: hit.schedule_category,
        batches: hit.batches,
      },
    ]);
    setQuery("");
    setHits([]);
    searchRef.current?.focus();
  }

  useEffect(() => {
    function onKey(event: KeyboardEvent) {
      if (event.key === "F3") {
        event.preventDefault();
        searchRef.current?.focus();
      }
      if (event.key === "F2") {
        event.preventDefault();
        void finish();
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  async function finish() {
    if (lock.current || cart.length === 0) return;
    const nextPayments = payments.map((payment, index) => (
      index === 0 && payments.length === 1 && !(Number(payment.amount) > 0) && total
        ? { ...payment, amount: total }
        : payment
    )).filter((payment) => Number(payment.amount) > 0);
    if (nextPayments.length === 0) {
      toast.error("Enter the payment amount, or click Pay exact. Cash tendered is the cash the customer handed you.");
      return;
    }
    const cashPaid = nextPayments.filter((payment) => payment.method === "cash").reduce((sum, payment) => sum + Number(payment.amount), 0);
    if (cashPaid > 0 && Number(tendered || 0) < cashPaid) {
      toast.error(`Cash received must be at least ₹${cashPaid.toFixed(2)}. Enter it in Cash tendered.`);
      return;
    }
    lock.current = true;
    setBusy(true);
    const result = await completeSale({ ...payload, payments: nextPayments });
    setBusy(false);
    lock.current = false;
    if (!result.ok) {
      toast.error(result.message);
      return;
    }
    const invoice = result.data as { invoice_id: string; invoice_number: string; replayed?: boolean };
    toast.success(invoice.replayed ? `Opened ${invoice.invoice_number}` : `Bill ${invoice.invoice_number} posted`);
    router.push(`/sales/${invoice.invoice_id}/print`);
  }

  const total = quote?.totals?.grand_total;

  return (
    <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_360px]">
      <section className="rounded-2xl border border-slate-200 bg-white p-4">
        <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
          <h1 className="text-2xl font-semibold">Billing</h1>
          <p className="text-sm text-slate-600">
            Prices are GST {pricingMode}. F3 searches, F2 completes the bill.
          </p>
        </div>
        <Input
          ref={searchRef}
          autoFocus
          value={query}
          placeholder="Name, generic, code, or barcode"
          onChange={(event) => setQuery(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && hits[0]) {
              event.preventDefault();
              addMedicine(hits[0]);
            }
          }}
        />
        {hits.length > 0 ? (
          <div className="mt-2 max-h-64 overflow-auto rounded-xl border">
            {hits.map((hit) => (
              <button key={hit.id} type="button" className="block w-full border-b px-3 py-2 text-left hover:bg-brand-50" onClick={() => addMedicine(hit)}>
                <span className="font-medium">{hit.name}</span>
                <span className="ml-2 text-sm text-slate-500">{hit.strength} {hit.dosage_form} · {hit.generic_name}</span>
                {hit.prescription_required ? <span className="ml-2 rounded bg-amber-100 px-2 py-0.5 text-xs font-semibold text-amber-800">Rx</span> : null}
                <span className="mt-1 block text-xs text-slate-500">
                  {hit.batches?.length ? `${hit.batches.length} saleable batch${hit.batches.length > 1 ? "es" : ""}` : "No saleable stock. Receive it through a purchase before billing."}
                </span>
              </button>
            ))}
          </div>
        ) : null}
        <div className="mt-4 overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead className="text-left text-xs uppercase text-slate-500">
              <tr>
                <th className="py-2">Medicine</th>
                <th>Batch</th>
                <th>Qty</th>
                <th>Price</th>
                <th>Discount</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {cart.length === 0 ? (
                <tr><td colSpan={6} className="py-8 text-center text-slate-500">Search a medicine to start the bill.</td></tr>
              ) : cart.map((line) => (
                <tr key={line.key} className="border-t">
                  <td className="py-2 pr-2">
                    <div className="font-medium">{line.name}</div>
                    <div className="text-xs text-slate-500">{line.strength} {line.dosageForm} {line.prescription ? "· Rx" : ""} {line.nearExpiry ? "· Near expiry" : ""}</div>
                  </td>
                  <td>
                    <Select value={line.batchId} onChange={(event) => {
                      const batch = line.batches.find((item) => item.id === event.target.value);
                      if (!batch) return;
                      setCart((current) => current.map((item) => item.key === line.key ? {
                        ...item,
                        batchId: batch.id,
                        batchNumber: batch.batch_number,
                        expiry: batch.expiry_date,
                        unitPrice: canOverridePrice ? item.unitPrice : batch.selling_price,
                        mrp: batch.mrp,
                        nearExpiry: batch.near_expiry,
                      } : item));
                    }}>
                      {line.batches.map((batch) => (
                        <option key={batch.id} value={batch.id}>
                          {batch.batch_number} · exp {formatDateOnly(batch.expiry_date)} · qty {Number(batch.qty_available)}
                        </option>
                      ))}
                    </Select>
                  </td>
                  <td className="w-28"><Input value={line.quantity} onChange={(event) => setCart((current) => current.map((item) => item.key === line.key ? { ...item, quantity: event.target.value } : item))} /></td>
                  <td className="w-28"><Input value={line.unitPrice} disabled={!canOverridePrice} onChange={(event) => setCart((current) => current.map((item) => item.key === line.key ? { ...item, unitPrice: event.target.value } : item))} /></td>
                  <td className="w-28"><Input value={line.discountAmount} onChange={(event) => setCart((current) => current.map((item) => item.key === line.key ? { ...item, discountAmount: event.target.value } : item))} /></td>
                  <td><button type="button" className="text-rose-700" onClick={() => setCart((current) => current.filter((item) => item.key !== line.key))}>Remove</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
      <aside className="space-y-4 rounded-2xl border border-slate-200 bg-white p-4">
        <div>
          <p className="text-xs font-semibold uppercase text-slate-500">Customer</p>
          <Input className="mt-2" value={customerQuery} placeholder="Search name or phone" onChange={(event) => setCustomerQuery(event.target.value)} />
          {customers.map((customer) => (
            <button key={customer.id} type="button" className="mt-1 block w-full rounded-lg px-2 py-1 text-left text-sm hover:bg-brand-50" onClick={() => { setCustomerId(customer.id); setCustomerName(customer.name); setCustomerQuery(""); setCustomers([]); }}>
              {customer.name} · due {formatINR(customer.outstanding_balance)}
            </button>
          ))}
          <p className="mt-2 text-sm">Billing to <strong>{customerName}</strong></p>
          {customerId ? <button type="button" className="text-xs text-slate-500" onClick={() => { setCustomerId(null); setCustomerName("Walk-in"); }}>Use walk-in</button> : null}
        </div>
        <label className="block text-sm">Bill discount
          <Input className="mt-1" value={billDiscount} onChange={(event) => setBillDiscount(event.target.value)} />
        </label>
        {quote?.warnings?.includes("near_expiry") ? (
          <label className="flex items-start gap-2 rounded-xl bg-amber-50 p-3 text-sm text-amber-900">
            <input type="checkbox" checked={ackExpiry} onChange={(event) => setAckExpiry(event.target.checked)} />
            A selected batch expires soon. Confirm before selling it.
          </label>
        ) : null}
        {quote?.prescription_required ? (
          <label className="block text-sm">Prescription note
            <Input className="mt-1" value={note} onChange={(event) => setNote(event.target.value)} placeholder="Reference only. No diagnosis." />
          </label>
        ) : null}
        <div>
          <p className="text-xs font-semibold uppercase text-slate-500">Payment</p>
          {payments.map((payment, index) => (
            <div key={index} className="mt-2 grid grid-cols-[1fr_1fr] gap-2">
              <Select value={payment.method} onChange={(event) => setPayments((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, method: event.target.value } : item))}>
                <option value="cash">Cash</option>
                <option value="upi">UPI</option>
                <option value="card">Card</option>
                <option value="bank_transfer">Bank transfer</option>
                {allowCredit ? <option value="credit">Credit</option> : null}
              </Select>
              <Input value={payment.amount} onChange={(event) => setPayments((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, amount: event.target.value } : item))} />
            </div>
          ))}
          <div className="mt-2 flex gap-2">
            <Button type="button" variant="secondary" size="sm" onClick={() => setPayments((current) => [...current, { method: "upi", amount: "" }])}>Split</Button>
            <Button type="button" variant="secondary" size="sm" onClick={() => total && setPayments([{ method: defaultMethod, amount: total }])}>Pay exact</Button>
          </div>
          <label className="mt-3 block text-sm">Cash tendered
            <Input className="mt-1" value={tendered} onChange={(event) => setTendered(event.target.value)} />
          </label>
        </div>
        <div className="rounded-xl bg-brand-50 p-3 text-sm">
          <div className="flex justify-between"><span>Taxable</span><span>{formatINR(quote?.totals?.taxable_value)}</span></div>
          <div className="flex justify-between"><span>CGST</span><span>{formatINR(quote?.totals?.cgst)}</span></div>
          <div className="flex justify-between"><span>SGST</span><span>{formatINR(quote?.totals?.sgst)}</span></div>
          <div className="flex justify-between"><span>IGST</span><span>{formatINR(quote?.totals?.igst)}</span></div>
          <div className="mt-2 flex justify-between text-lg font-semibold"><span>Total</span><span>{formatINR(total)}</span></div>
          <p className="mt-1 text-xs text-slate-600">{quote?.invoice_kind === "tax_invoice" ? "Will be saved as a tax invoice." : "Will be saved as a retail bill, not a GST tax invoice."}</p>
        </div>
        {quoteError ? <p className="text-sm text-rose-700">{quoteError}</p> : null}
        <Button size="lg" className="w-full" disabled={busy || cart.length === 0} onClick={() => void finish()}>{busy ? "Posting..." : "Complete bill"}</Button>
        <Button variant="secondary" className="w-full" onClick={async () => {
          const result = await saveDraft(payload);
          if (result.ok) toast.success("Draft saved");
          else toast.error(result.message);
        }}>Save draft</Button>
      </aside>
    </div>
  );
}
