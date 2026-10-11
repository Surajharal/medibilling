import { InviteForm, SettingsForm } from "@/components/settings-form";
import { PageHeader } from "@/components/page-header";
import { requireAction } from "@/lib/tenant";

export default async function SettingsPage() {
  const context = await requireAction("settings.manage");
  const { data: members } = await context.supabase.from("pharmacy_memberships").select("role, is_active, user_id, user_profiles(full_name, email)").eq("pharmacy_id", context.pharmacy.id);
  return (
    <div className="space-y-8">
      <PageHeader title="Pharmacy settings" description="Invoice numbers are allocated inside the posting transaction and stay unique for the financial year." />
      <SettingsForm pharmacy={context.pharmacy} />
      <section>
        <h2 className="mb-3 font-semibold">Staff</h2>
        <ul className="mb-4 space-y-1 text-sm">
          {(members ?? []).map((member) => (
            <li key={member.user_id}>{(member.user_profiles as { full_name?: string; email?: string } | null)?.full_name} · {(member.user_profiles as { email?: string } | null)?.email} · {member.role}</li>
          ))}
        </ul>
        <InviteForm />
      </section>
    </div>
  );
}
