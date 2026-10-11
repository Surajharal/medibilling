/** Indian-style financial year label, for example 2026-27 when the year starts in April. */
export function financialYearLabel(isoDate: string, startMonth = 4): string {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(isoDate);
  if (!match) throw new Error("invalid_date");
  const year = Number(match[1]);
  const month = Number(match[2]);
  const startYear = month >= startMonth ? year : year - 1;
  const end = String((startYear + 1) % 100).padStart(2, "0");
  return `${startYear}-${end}`;
}

export function invoiceNumber(prefix: string, financialYear: string, sequence: number): string {
  return `${prefix}/${financialYear}/${String(sequence).padStart(6, "0")}`;
}
