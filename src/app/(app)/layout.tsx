import { AppShell } from "@/components/app-shell";
import { publicEnv } from "@/lib/env";
import { NAV_ITEMS, can } from "@/lib/permissions";
import { getSessionContext } from "@/lib/tenant";

export const dynamic = "force-dynamic";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  if (!publicEnv().configured) {
    return (
      <main className="mx-auto max-w-xl px-6 py-16">
        <h1 className="text-2xl font-semibold">Connect Supabase</h1>
        <p className="mt-3 text-sm text-slate-600">
          Copy <code>.env.example</code> to <code>.env.local</code> and add the project URL and publishable key. The service-role key stays on the server.
        </p>
      </main>
    );
  }
  const context = await getSessionContext();
  const items = NAV_ITEMS.filter((item) => can(context.role, item.action)).map(({ href, label }) => ({ href, label }));
  return (
    <AppShell
      pharmacyName={context.pharmacy.name}
      role={context.role}
      userEmail={context.user.email ?? ""}
      items={items}
      stores={context.memberships}
      currentPharmacyId={context.pharmacy.id}
    >
      {children}
    </AppShell>
  );
}
