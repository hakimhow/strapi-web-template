// Strapi v5 客户端 —— SSR 时优先走 INTERNAL_STRAPI_URL（docker 内网），
// 浏览器侧走 PUBLIC_STRAPI_URL。
//
// v5 响应格式（扁平，没有 .attributes 包裹）：
//   { data: [{ id, documentId, title, slug, ... }], meta: { pagination: {...} } }

const INTERNAL = import.meta.env.INTERNAL_STRAPI_URL ?? process.env.INTERNAL_STRAPI_URL;
const PUBLIC = import.meta.env.PUBLIC_STRAPI_URL;
const TOKEN = import.meta.env.STRAPI_PUBLIC_TOKEN ?? process.env.STRAPI_PUBLIC_TOKEN;

export function strapiBase(): string {
  if (import.meta.env.SSR && INTERNAL) return INTERNAL;
  return PUBLIC;
}

/** v5 实体基础字段：documentId（字符串）是内容的稳定引用，id 仅在数据库内部用 */
export interface StrapiEntity {
  id: number;
  documentId: string;
  createdAt?: string;
  updatedAt?: string;
  publishedAt?: string;
  locale?: string | null;
}

export interface StrapiList<T> {
  data: Array<T & StrapiEntity>;
  meta: {
    pagination: { page: number; pageSize: number; pageCount: number; total: number };
  };
}

export interface StrapiSingle<T> {
  data: (T & StrapiEntity) | null;
  meta: Record<string, unknown>;
}

export interface StrapiListParams {
  filters?: Record<string, unknown>;
  sort?: string | string[];
  pagination?: { page?: number; pageSize?: number; withCount?: boolean };
  populate?: string | string[] | Record<string, unknown>;
  fields?: string[];
  status?: 'published' | 'draft';   // v5：替代 v4 的 publicationState
  locale?: string;
}

function qs(params: StrapiListParams): string {
  const sp = new URLSearchParams();
  if (params.sort) ([] as string[]).concat(params.sort).forEach((s) => sp.append('sort', s));
  if (params.pagination?.page) sp.set('pagination[page]', String(params.pagination.page));
  if (params.pagination?.pageSize) sp.set('pagination[pageSize]', String(params.pagination.pageSize));
  if (params.pagination?.withCount !== undefined) sp.set('pagination[withCount]', String(params.pagination.withCount));
  if (params.populate) sp.set('populate', JSON.stringify(params.populate));
  if (params.fields) params.fields.forEach((f, i) => sp.set(`fields[${i}]`, f));
  if (params.status) sp.set('status', params.status);
  if (params.locale) sp.set('locale', params.locale);
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
  const url = `${strapiBase()}/api${path}${Object.keys(params).length ? `?${qs(params)}` : ''}`;
  const res = await fetch(url, {
    headers: TOKEN ? { Authorization: `Bearer ${TOKEN}` } : {},
  });
  if (!res.ok) throw new Error(`Strapi ${res.status} ${res.statusText}: ${url}`);
  return (await res.json()) as T;
}

export function imagorUrl(src: string, opts: { width?: number; height?: number; fit?: 'fit-in' | 'smart' } = {}): string {
  const base = import.meta.env.PUBLIC_IMAGOR_URL;
  const parts: string[] = [];
  if (opts.fit) parts.push(opts.fit);
  if (opts.width || opts.height) parts.push(`${opts.width ?? 0}x${opts.height ?? 0}`);
  parts.push(src.replace(/^https?:\/\//, ''));
  return `${base}/unsafe/${parts.join('/')}`;
}
