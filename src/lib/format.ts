import { moneyStr } from "@/lib/money";

const INR = new Intl.NumberFormat("en-IN", {
  style: "currency",
  currency: "INR",
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

export function formatINR(value: string | number | null | undefined): string {
  if (value === null || value === undefined || value === "") return "₹0.00";
  const normalized = moneyStr(value);
  return INR.format(Number(normalized));
}

export function formatQty(value: string | number | null | undefined): string {
  if (value === null || value === undefined || value === "") return "0";
  const n = Number(value);
  if (Number.isInteger(n)) return String(n);
  return n.toLocaleString("en-IN", { maximumFractionDigits: 3 });
}

function partsInZone(value: string | Date, timeZone: string) {
  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) return null;
  return new Intl.DateTimeFormat("en-GB", {
    timeZone,
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);
}

function part(
  parts: Intl.DateTimeFormatPart[] | null,
  type: Intl.DateTimeFormatPartTypes,
) {
  return parts?.find((item) => item.type === type)?.value ?? "";
}

/** Date-only values (expiry, invoice date) are formatted without shifting the calendar day. */
export function formatDateOnly(value: string | null | undefined): string {
  if (!value) return "—";
  const match = /^(\d{4})-(\d{2})-(\d{2})/.exec(value);
  if (!match) return value;
  return `${match[3]}-${match[2]}-${match[1]}`;
}

export function formatDateTime(
  value: string | Date | null | undefined,
  timeZone = "Asia/Kolkata",
): string {
  if (!value) return "—";
  const parts = partsInZone(value, timeZone);
  if (!parts) return "—";
  return `${part(parts, "day")}-${part(parts, "month")}-${part(parts, "year")} ${part(parts, "hour")}:${part(parts, "minute")}`;
}

export function formatDate(
  value: string | Date | null | undefined,
  timeZone = "Asia/Kolkata",
): string {
  if (!value) return "—";
  if (typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value)) {
    return formatDateOnly(value);
  }
  const parts = partsInZone(value, timeZone);
  if (!parts) return "—";
  return `${part(parts, "day")}-${part(parts, "month")}-${part(parts, "year")}`;
}

export function todayInTimeZone(timeZone = "Asia/Kolkata"): string {
  const parts = partsInZone(new Date(), timeZone);
  if (!parts) return new Date().toISOString().slice(0, 10);
  return `${part(parts, "year")}-${part(parts, "month")}-${part(parts, "day")}`;
}

export function addDays(isoDate: string, days: number): string {
  const [year, month, day] = isoDate.split("-").map(Number);
  const utc = new Date(Date.UTC(year, month - 1, day));
  utc.setUTCDate(utc.getUTCDate() + days);
  return utc.toISOString().slice(0, 10);
}
