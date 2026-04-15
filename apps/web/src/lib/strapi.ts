// Strapi 客户端（SSG）—— 只在 build 时在 Node 里执行。
// 浏览器端不用这个模块；动态搜索直接 fetch('/api/...') 让 nginx 代理。

const BUILD_STRAPI_URL =
  process.env.INTERNAL_STRAPI_URL ||
  process.env.PUBLIC_STRAPI_URL ||
  'http://localhost:1337';

const TOKEN = process.env.STRAPI_PUBLIC_TOKEN;

export interface StrapiListParams {
  filters?: Record<string, unknown>;
  sort?: string | string[];
  pagination?: { page?: number; pageSize?: number };
  populate?: string | string[] | Record<string, unknown>;
}

function qs(params: StrapiListParams): string {
  const sp = new URLSearchParams();
  if (params.sort) {
    ([] as string[]).concat(params.sort).forEach((s) => sp.append('sort', s));
  }
  if (params.pagination?.page) sp.set('pagination[page]', String(params.pagination.page));
  if (params.pagination?.pageSize) sp.set('pagination[pageSize]', String(params.pagination.pageSize));
  if (params.populate) sp.set('populate', JSON.stringify(params.populate));
  if (params.filters) {
    const flat = (obj: Record<string, unknown>, prefix = 'filters'): void => {
      for (const [k, v] of Object.entries(obj)) {
        const key = `${prefix}[${k}]`;
        if (v && typeof v === 'object' && !Array.isArray(v)) flat(v as Record<string, unknown>, key);
        else sp.set(key, String(v));
      }
    };
    flat(params.filters);
  }
  return sp.toString();
}

export async function strapiGet<T>(path: string, params: StrapiListParams = {}): Promise<T> {
  const url = `${BUILD_STRAPI_URL}/api${path}${Object.keys(params).length ? `?${qs(params)}` : ''}`;
  const res = await fetch(url, {
    headers: TOKEN ? { Authorization: `Bearer ${TOKEN}` } : {},
  });
  if (!res.ok) throw new Error(`Strapi ${res.status} ${res.statusText}: ${url}`);
  return (await res.json()) as T;
}

export function imagorUrl(src: string, opts: { width?: number; height?: number; fit?: 'fit-in' | 'smart' } = {}): string {
  const base = process.env.PUBLIC_IMAGOR_URL || '/cdn';
  const parts: string[] = [];
  if (opts.fit) parts.push(opts.fit);
  if (opts.width || opts.height) parts.push(`${opts.width ?? 0}x${opts.height ?? 0}`);
  parts.push(src.replace(/^https?:\/\//, ''));
  return `${base}/unsafe/${parts.join('/')}`;
}
