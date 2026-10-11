import { cn } from "@/lib/utils";

export function Card({ className, ...props }: React.ComponentProps<"section">) {
  return <section className={cn("rounded-2xl border border-slate-200 bg-white p-5 shadow-sm", className)} {...props} />;
}

export function Badge({
  tone = "neutral",
  children,
}: {
  tone?: "neutral" | "good" | "warning" | "danger";
  children: React.ReactNode;
}) {
  const tones = {
    neutral: "bg-slate-100 text-slate-700",
    good: "bg-emerald-50 text-emerald-800",
    warning: "bg-amber-50 text-amber-800",
    danger: "bg-rose-50 text-rose-800",
  };
  return <span className={cn("inline-flex rounded-full px-2.5 py-1 text-xs font-semibold", tones[tone])}>{children}</span>;
}
