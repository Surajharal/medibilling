"use client";

import { CartesianGrid, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { formatDateOnly } from "@/lib/format";

export function SalesTrend({ points }: { points: { period: string; total: string }[] }) {
  const data = points.map((point) => ({
    period: formatDateOnly(point.period),
    total: Number(point.total),
  }));
  if (data.length === 0) return <p className="text-sm text-slate-500">No posted sales in this range.</p>;
  return (
    <div className="h-72">
      <ResponsiveContainer width="100%" height="100%">
        <LineChart data={data}>
          <CartesianGrid strokeDasharray="3 3" />
          <XAxis dataKey="period" />
          <YAxis />
          <Tooltip />
          <Line type="monotone" dataKey="total" stroke="#16635a" strokeWidth={2} dot={false} />
        </LineChart>
      </ResponsiveContainer>
    </div>
  );
}
