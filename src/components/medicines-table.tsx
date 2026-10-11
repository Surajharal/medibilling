"use client";

import Link from "next/link";
import { createColumnHelper } from "@tanstack/react-table";
import { SortableTable } from "@/components/sortable-table";
import { Badge } from "@/components/ui/card";
import { formatINR } from "@/lib/format";

export type MedicineRow = {
  id: string;
  medicine_code: string;
  name: string;
  strength: string;
  dosage_form: string;
  gst_rate: number;
  mrp: number;
  is_active: boolean;
};

const helper = createColumnHelper<MedicineRow>();
const columns = [
  helper.accessor("medicine_code", { header: "Code" }),
  helper.accessor("name", {
    header: "Medicine",
    cell: (info) => <Link className="font-medium text-brand-800" href={`/medicines/${info.row.original.id}`}>{info.getValue()}</Link>,
  }),
  helper.accessor("strength", { header: "Strength" }),
  helper.accessor("dosage_form", { header: "Form" }),
  helper.accessor("gst_rate", { header: "GST %", cell: (info) => `${info.getValue()}%` }),
  helper.accessor("mrp", { header: "MRP", cell: (info) => formatINR(info.getValue()) }),
  helper.accessor("is_active", {
    header: "Status",
    cell: (info) => <Badge tone={info.getValue() ? "good" : "neutral"}>{info.getValue() ? "Active" : "Inactive"}</Badge>,
  }),
];

export function MedicinesTable({ rows }: { rows: MedicineRow[] }) {
  return <SortableTable columns={columns} data={rows} />;
}
