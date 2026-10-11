"use server";

import { z } from "zod";
import { DOSAGE_FORMS, SCHEDULES } from "@/lib/catalog";
import { requireAction } from "@/lib/tenant";

const lookupSchema = z.object({
  name: z.string().trim().max(200).catch(""),
  generic_name: z.string().trim().max(200).catch(""),
  brand_name: z.string().trim().max(200).catch(""),
  manufacturer: z.string().trim().max(160).catch(""),
  strength: z.string().trim().max(80).catch(""),
  dosage_form: z.string().trim().max(40).catch(""),
  composition: z.string().trim().max(500).catch(""),
  hsn_code: z.string().trim().max(12).catch(""),
  schedule_category: z.string().trim().max(8).catch(""),
});

export type MedicineLookup = {
  name: string;
  generic_name: string;
  brand_name: string;
  manufacturer: string;
  strength: string;
  dosage_form: string;
  composition: string;
  hsn_code: string;
  schedule_category: string;
};

function fail(message: string) {
  return { ok: false as const, message };
}

function parseModelJson(text: string) {
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/);
  const raw = fenced?.[1] ?? text;
  const start = raw.indexOf("{");
  const end = raw.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  try {
    return JSON.parse(raw.slice(start, end + 1)) as unknown;
  } catch {
    return null;
  }
}

const MODELS = ["gemini-3.5-flash", "gemini-flash-lite-latest"];

function lookupPrompt(query: string) {
  return [
    "Look up this Indian retail medicine from published product information.",
    "Return only one JSON object with these keys:",
    "name, generic_name, brand_name, manufacturer, strength, dosage_form, composition, hsn_code, schedule_category.",
    "generic_name is the salt or active ingredients. composition is the full contents with quantities when published.",
    `dosage_form must be one of: ${DOSAGE_FORMS.join(", ")}.`,
    `schedule_category must be one of: ${SCHEDULES.join(", ")}. Use OTC when the schedule is not published.`,
    "hsn_code is the Indian GST code, digits only, or an empty string.",
    "Do not invent ingredients. If the published contents cannot be found, return empty strings for generic_name and composition.",
    `Medicine: ${query}`,
  ].join("\n");
}

async function askGemini(model: string, key: string, query: string, useSearch: boolean) {
  return fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-goog-api-key": key,
      },
      signal: AbortSignal.timeout(20000),
      body: JSON.stringify({
        contents: [{ role: "user", parts: [{ text: lookupPrompt(query) }] }],
        ...(useSearch ? { tools: [{ google_search: {} }] } : {}),
        generationConfig: { temperature: 0.1 },
      }),
    },
  );
}

export async function lookupMedicine(query: string) {
  await requireAction("medicines.manage");
  const name = query.trim().slice(0, 120);
  if (name.length < 2) return fail("Enter the medicine name first.");
  const key = process.env.GEMINI_API_KEY?.trim() ?? "";
  if (!key) return fail("Add GEMINI_API_KEY in .env.local, then restart the app.");

  let response: Response | null = null;
  try {
    for (const model of MODELS) {
      response = await askGemini(model, key, name, true);
      if (response.status === 400 || response.status === 429) response = await askGemini(model, key, name, false);
      if (response.ok) break;
      if (response.status === 401 || response.status === 403) {
        return fail("The Gemini API key was rejected. Check the key in .env.local and restart the app.");
      }
    }
  } catch {
    return fail("The medicine lookup timed out. Try again.");
  }

  if (!response?.ok) {
    return fail(response?.status === 429
      ? "The Gemini free quota for this key is used up. Wait a minute and try again."
      : "The medicine lookup could not be completed. Try again.");
  }

  const body = await response.json() as {
    candidates?: { content?: { parts?: { text?: string }[] } }[];
  };
  const text = (body.candidates?.[0]?.content?.parts ?? []).map((part) => part.text ?? "").join("\n");
  const parsed = lookupSchema.safeParse(parseModelJson(text));
  if (!parsed.success || (!parsed.data.generic_name && !parsed.data.composition)) {
    return fail("No published contents were found for that name. Check the spelling or try the brand name.");
  }

  const dosage = DOSAGE_FORMS.find((form) => form === parsed.data.dosage_form.toLowerCase()) ?? "";
  const schedule = SCHEDULES.find((item) => item === parsed.data.schedule_category.toUpperCase()) ?? "";
  const data: MedicineLookup = {
    ...parsed.data,
    dosage_form: dosage,
    schedule_category: schedule,
    hsn_code: parsed.data.hsn_code.replace(/\D/g, "").slice(0, 8),
  };
  return { ok: true as const, data };
}
