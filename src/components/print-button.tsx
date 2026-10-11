"use client";

export function PrintButton() {
  return (
    <button type="button" className="rounded-lg bg-brand-700 px-3 py-2 text-sm text-white" onClick={() => window.print()}>
      Print
    </button>
  );
}
