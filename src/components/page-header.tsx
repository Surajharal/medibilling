export function PageHeader({ title, description, action }: { title: string; description?: string; action?: React.ReactNode }) {
  return (
    <div className="mb-6 flex flex-wrap items-end justify-between gap-3">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight text-brand-950">{title}</h1>
        {description ? <p className="mt-1 max-w-3xl text-sm text-slate-600">{description}</p> : null}
      </div>
      {action}
    </div>
  );
}

export function Pager({ page, hasMore, path, query }: { page: number; hasMore: boolean; path: string; query: Record<string, string | undefined> }) {
  const href = (nextPage: number) => {
    const params = new URLSearchParams();
    Object.entries(query).forEach(([key, value]) => {
      if (value) params.set(key, value);
    });
    params.set("page", String(nextPage));
    return `${path}?${params.toString()}`;
  };
  return (
    <div className="mt-4 flex items-center justify-between text-sm">
      <span className="text-slate-500">Page {page}</span>
      <div className="flex gap-2">
        {page > 1 ? <a className="rounded-lg border bg-white px-3 py-2" href={href(page - 1)}>Previous</a> : null}
        {hasMore ? <a className="rounded-lg border bg-white px-3 py-2" href={href(page + 1)}>Next</a> : null}
      </div>
    </div>
  );
}
