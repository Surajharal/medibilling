export default function ForbiddenPage() {
  return (
    <main className="mx-auto max-w-lg py-16">
      <h1 className="text-2xl font-semibold">You cannot open this page</h1>
      <p className="mt-2 text-sm text-slate-600">Your role does not include this part of the store. Ask the owner if your work needs it.</p>
      <a className="mt-6 inline-block text-sm font-semibold text-brand-800" href="/dashboard">Back to the dashboard</a>
    </main>
  );
}
