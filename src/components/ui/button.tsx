import { cva, type VariantProps } from "class-variance-authority";
import { Slot } from "@radix-ui/react-slot";
import { cn } from "@/lib/utils";

const buttonVariants = cva(
  "inline-flex items-center justify-center gap-2 rounded-xl text-sm font-semibold transition disabled:pointer-events-none disabled:opacity-50 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand-700",
  {
    variants: {
      variant: {
        primary: "bg-brand-700 text-white hover:bg-brand-800",
        secondary: "bg-white text-ink border border-slate-200 hover:bg-slate-50",
        danger: "bg-rose-700 text-white hover:bg-rose-800",
        ghost: "hover:bg-brand-50 text-brand-900",
      },
      size: {
        sm: "h-9 px-3",
        md: "h-11 px-4",
        lg: "h-14 px-5 text-base",
      },
    },
    defaultVariants: { variant: "primary", size: "md" },
  },
);

export function Button({
  className,
  variant,
  size,
  asChild,
  ...props
}: React.ComponentProps<"button"> & VariantProps<typeof buttonVariants> & { asChild?: boolean }) {
  const Comp = asChild ? Slot : "button";
  return <Comp className={cn(buttonVariants({ variant, size }), className)} {...props} />;
}
