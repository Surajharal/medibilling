"use client";

export default function AppError({ reset }: { error: Error; reset: () => void }) {
  return (
    <div className="rounded-2xl border bg-white p-6">
      <h1 className="text-lg font-semibold">Something went wrong</h1>
      <p className="mt-2 text-sm text-slate-600">The page could not be loaded. Try again, or return to the dashboard.</p>
      <button type="button" className="mt-4 rounded-xl bg-brand-700 px-4 py-2 text-sm font-semibold text-white" onClick={reset}>
        Try again
      </button>
    </div>
  );
}
