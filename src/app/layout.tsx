import { Figtree, JetBrains_Mono } from "next/font/google";
import { Toaster } from "sonner";
import "./globals.css";

const sans = Figtree({ subsets: ["latin"], variable: "--font-figtree" });
const mono = JetBrains_Mono({ subsets: ["latin"], variable: "--font-mono" });

export const metadata = {
  title: { default: "MediBilling", template: "%s · MediBilling" },
  description: "Billing, inventory, and GST records for a retail medical store.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className={`${sans.variable} ${mono.variable} font-sans antialiased`}>
        {children}
        <Toaster richColors position="top-right" />
      </body>
    </html>
  );
}
