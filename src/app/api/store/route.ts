import { cookies } from "next/headers";
import { NextResponse } from "next/server";

export async function POST(request: Request) {
  const form = await request.formData();
  const pharmacyId = String(form.get("pharmacyId") ?? "");
  const cookieStore = await cookies();
  if (pharmacyId) {
    cookieStore.set("mb_pharmacy", pharmacyId, { httpOnly: true, sameSite: "lax", path: "/" });
  }
  return NextResponse.redirect(new URL("/dashboard", request.url));
}
