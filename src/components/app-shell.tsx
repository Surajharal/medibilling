"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useState } from "react";
import {
  BarChart3,
  Boxes,
  LayoutDashboard,
  LogOut,
  Menu,
  Pill,
  ReceiptText,
  RotateCcw,
  ScrollText,
  Settings,
  Truck,
  Users,
  X,
} from "lucide-react";
import { logout } from "@/server/auth";
import { roleLabel, type Role } from "@/lib/permissions";
import { cn } from "@/lib/utils";

const ICONS: Record<string, React.ComponentType<{ className?: string }>> = {
  "/dashboard": LayoutDashboard,
  "/billing": ReceiptText,
  "/sales": ReceiptText,
  "/medicines": Pill,
  "/inventory": Boxes,
  "/purchases": Truck,
  "/suppliers": Truck,
  "/customers": Users,
  "/returns": RotateCcw,
  "/reports": BarChart3,
  "/settings": Settings,
  "/audit": ScrollText,
};

export function AppShell({
  pharmacyName,
  role,
  userEmail,
  items,
  stores,
  currentPharmacyId,
  children,
}: {
  pharmacyName: string;
  role: Role;
  userEmail: string;
  items: { href: string; label: string }[];
  stores: { pharmacyId: string; name: string }[];
  currentPharmacyId: string;
  children: React.ReactNode;
}) {
  const pathname = usePathname();
  const [open, setOpen] = useState(false);
  const [collapsed, setCollapsed] = useState(false);

  return (
    <div className="min-h-screen lg:grid lg:grid-cols-[auto_1fr]">
      <aside className={cn("no-print bg-brand-950 text-brand-50 lg:min-h-screen", collapsed ? "lg:w-20" : "lg:w-64", open ? "block" : "hidden lg:block")}>
        <div className="flex items-center justify-between px-4 py-5">
          <Link href="/dashboard" className="flex items-center gap-3">
            <span className="grid h-10 w-10 place-items-center rounded-xl bg-brand-600 font-bold">M</span>
            {collapsed ? null : <span className="text-lg font-semibold tracking-tight">MediBilling</span>}
          </Link>
          <button type="button" className="hidden lg:inline text-brand-100" onClick={() => setCollapsed((value) => !value)} aria-label="Collapse menu">
            <Menu className="h-5 w-5" />
          </button>
        </div>
        <nav className="space-y-1 px-3">
          {items.map((item) => {
            const Icon = ICONS[item.href] ?? LayoutDashboard;
            const active = pathname === item.href || pathname.startsWith(`${item.href}/`);
            return (
              <Link
                key={item.href}
                href={item.href}
                onClick={() => setOpen(false)}
                className={cn(
                  "flex items-center gap-3 rounded-xl px-3 py-2.5 text-sm font-medium",
                  active ? "bg-brand-700 text-white" : "text-brand-100 hover:bg-white/10",
                )}
              >
                <Icon className="h-5 w-5 shrink-0" />
                {collapsed ? null : item.label}
              </Link>
            );
          })}
        </nav>
      </aside>
      <div className="min-w-0">
        <header className="no-print sticky top-0 z-20 flex items-center justify-between gap-3 border-b border-slate-200 bg-paper/95 px-4 py-3 backdrop-blur">
          <button type="button" className="lg:hidden" onClick={() => setOpen((value) => !value)} aria-label="Open menu">
            {open ? <X /> : <Menu />}
          </button>
          <div className="min-w-0">
            <p className="truncate text-sm font-semibold">{pharmacyName}</p>
            <p className="text-xs text-slate-500">{roleLabel(role)}</p>
          </div>
          <div className="ml-auto flex items-center gap-3">
            {stores.length > 1 ? (
              <form action="/api/store" method="post">
                <select
                  name="pharmacyId"
                  defaultValue={currentPharmacyId}
                  className="h-10 rounded-xl border border-slate-200 bg-white px-2 text-sm"
                  onChange={(event) => event.currentTarget.form?.requestSubmit()}
                >
                  {stores.map((store) => (
                    <option key={store.pharmacyId} value={store.pharmacyId}>
                      {store.name}
                    </option>
                  ))}
                </select>
              </form>
            ) : null}
            <span className="hidden text-xs text-slate-500 sm:inline">{userEmail}</span>
            <form action={logout}>
              <button type="submit" className="inline-flex items-center gap-2 rounded-xl px-3 py-2 text-sm hover:bg-white">
                <LogOut className="h-4 w-4" />
                Sign out
              </button>
            </form>
          </div>
        </header>
        <main className="px-4 py-6 lg:px-8">{children}</main>
      </div>
    </div>
  );
}
