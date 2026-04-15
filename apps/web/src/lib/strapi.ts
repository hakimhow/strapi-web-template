// Strapi 客户端 —— SSR 时优先走 INTERNAL_STRAPI_URL（docker 内网），
// 浏览器侧走 PUBLIC_STRAPI_URL。

const INTERNAL = import.meta.env.INTERNAL_STRAPI_URL ?? process.env.INTERNAL_STRAPI_URL;
const PUBLIC = import.meta.env.PUBLIC_STRAPI_URL;
const TOKEN = import.meta.env.STRAPI_PUBLIC_TOKEN ?? process.env.STRAPI_PUBLIC_TOKEN;

export function strapiBase(): string {
  // Astro SSR 在 Node 下执行时 import.meta.env.SSR === true
  if (import.meta.env.SSR && INTERNAL) return INTERNAL;
  return PUBLIC;
}

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
    // 简单扁平化：filters[field][op]=value
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
  const url = `${strapiBase()}/api${path}${Object.keys(params).length ? `?${qs(params)}` : ''}`;
  const res = await fetch(url, {
    headers: TOKEN ? { Authorization: `Bearer ${TOKEN}` } : {},
  });
  if (!res.ok) throw new Error(`Strapi ${res.status} ${res.statusText}: ${url}`);
  return (await res.json()) as T;
}

// Imagor 便捷 URL 生成（开发 unsafe，生产签名）
export function imagorUrl(src: string, opts: { width?: number; height?: number; fit?: 'fit-in' | 'smart' } = {}): string {
  const base = import.meta.env.PUBLIC_IMAGOR_URL;
  const parts: string[] = [];
  if (opts.fit) parts.push(opts.fit);
  if (opts.width || opts.height) parts.push(`${opts.width ?? 0}x${opts.height ?? 0}`);
  parts.push(src.replace(/^https?:\/\//, ''));
  return `${base}/unsafe/${parts.join('/')}`;
}
