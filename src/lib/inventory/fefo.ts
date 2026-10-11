export interface BatchCandidate {
  id: string;
  expiryDate: string;
  qtyAvailable: string;
  status: string;
  createdAt: string;
}

/** A batch may be sold through its expiry date, compared as a calendar date. */
export function isSaleableBatch(batch: BatchCandidate, today: string): boolean {
  return (
    batch.status === "active" &&
    Number(batch.qtyAvailable) > 0 &&
    batch.expiryDate >= today
  );
}

export function isNearExpiry(expiryDate: string, today: string, warningDays: number): boolean {
  const [year, month, day] = today.split("-").map(Number);
  const limit = new Date(Date.UTC(year, month - 1, day + warningDays));
  const limitIso = limit.toISOString().slice(0, 10);
  return expiryDate >= today && expiryDate <= limitIso;
}

export function selectFefo(batches: BatchCandidate[], today: string): BatchCandidate | null {
  return (
    batches
      .filter((batch) => isSaleableBatch(batch, today))
      .sort(
        (a, b) =>
          a.expiryDate.localeCompare(b.expiryDate) || a.createdAt.localeCompare(b.createdAt),
      )[0] ?? null
  );
}

export function isLowStock(saleableQty: string, reorderLevel: string, pharmacyThreshold: string): boolean {
  const level = Number(reorderLevel) > 0 ? Number(reorderLevel) : Number(pharmacyThreshold);
  return Number(saleableQty) <= level;
}

export function isOutOfStock(saleableQty: string): boolean {
  return Number(saleableQty) <= 0;
}

export type ExpiryState = "no_stock" | "all_expired" | "partial" | "ok";

/** One expired batch does not expire the medicine while another batch is saleable. */
export function medicineExpiryState(
  batches: { expiryDate: string; qtyAvailable: string; status: string }[],
  today: string,
): ExpiryState {
  const held = batches.filter((batch) => Number(batch.qtyAvailable) > 0 && batch.status !== "written_off");
  if (held.length === 0) return "no_stock";
  const expired = held.filter(
    (batch) => batch.expiryDate < today || batch.status === "expired",
  );
  if (expired.length === 0) return "ok";
  if (expired.length === held.length) return "all_expired";
  return "partial";
}
