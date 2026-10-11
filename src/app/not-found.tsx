import Link from "next/link";

export default function NotFound() {
  return (
    <main className="mx-auto max-w-lg px-6 py-16">
      <h1 className="text-2xl font-semibold">Page not found</h1>
      <p className="mt-2 text-sm text-slate-600">That record or page is not available for this store.</p>
      <Link className="mt-4 inline-block text-sm font-semibold text-brand-800" href="/dashboard">Back to the dashboard</Link>
    </main>
  );
}
