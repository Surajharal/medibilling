export const ROLES = ["owner", "pharmacist", "billing_operator"] as const;
export type Role = (typeof ROLES)[number];

export const ACTIONS = [
  "dashboard.view",
  "billing.create",
  "sales.view",
  "medicines.manage",
  "medicines.view",
  "inventory.view",
  "inventory.adjust",
  "purchases.manage",
  "suppliers.manage",
  "customers.manage",
  "customers.view",
  "returns.manage",
  "reports.view",
  "reports.profit",
  "settings.manage",
  "users.manage",
  "audit.view",
  "price.override",
] as const;

export type Action = (typeof ACTIONS)[number];

const MATRIX: Record<Role, ReadonlySet<Action>> = {
  owner: new Set(ACTIONS),
  pharmacist: new Set<Action>([
    "dashboard.view",
    "billing.create",
    "sales.view",
    "medicines.manage",
    "medicines.view",
    "inventory.view",
    "inventory.adjust",
    "purchases.manage",
    "suppliers.manage",
    "customers.manage",
    "customers.view",
    "returns.manage",
    "reports.view",
    "reports.profit",
    "price.override",
  ]),
  billing_operator: new Set<Action>([
    "dashboard.view",
    "billing.create",
    "sales.view",
    "medicines.view",
    "inventory.view",
    "customers.view",
    "customers.manage",
  ]),
};

export function isRole(value: string | null | undefined): value is Role {
  return ROLES.includes(value as Role);
}

export function can(role: Role, action: Action): boolean {
  return MATRIX[role].has(action);
}

export function roleLabel(role: Role): string {
  switch (role) {
    case "owner":
      return "Owner";
    case "pharmacist":
      return "Pharmacist";
    case "billing_operator":
      return "Billing operator";
  }
}

export const NAV_ITEMS: { href: string; label: string; action: Action }[] = [
  { href: "/dashboard", label: "Dashboard", action: "dashboard.view" },
  { href: "/billing", label: "Billing", action: "billing.create" },
  { href: "/sales", label: "Sales", action: "sales.view" },
  { href: "/medicines", label: "Medicines", action: "medicines.view" },
  { href: "/inventory", label: "Inventory", action: "inventory.view" },
  { href: "/purchases", label: "Purchases", action: "purchases.manage" },
  { href: "/suppliers", label: "Suppliers", action: "suppliers.manage" },
  { href: "/customers", label: "Customers", action: "customers.view" },
  { href: "/returns", label: "Returns", action: "returns.manage" },
  { href: "/reports", label: "Reports", action: "reports.view" },
  { href: "/settings", label: "Settings", action: "settings.manage" },
  { href: "/audit", label: "Audit log", action: "audit.view" },
];
