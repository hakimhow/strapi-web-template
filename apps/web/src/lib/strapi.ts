// Strapi v5 客户端（SSG）—— 只在 build 时在 Node 里执行。
// 浏览器端不用这个模块；动态搜索直接 fetch('/api/...') 让 nginx 代理。
//
// v5 关键差异：
//  - 响应是扁平的：data: [{ id, documentId, title, slug, ... }]，不再有 attributes 包裹
//  - 用 documentId 作为跨语言/版本的稳定 ID
//  - publicationState → status（'published' | 'draft'）
//  - i18n 内置，locale 直接写在顶层

const BUILD_STRAPI_URL =
  process.env.INTERNAL_STRAPI_URL ||
  process.env.PUBLIC_STRAPI_URL ||
  'http://localhost:1337';

const TOKEN = process.env.STRAPI_PUBLIC_TOKEN;

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
  status?: 'published' | 'draft'; // v5：替代 v4 的 publicationState
  locale?: string;
}

function qs(params: StrapiListParams): string {
  const sp = new URLSearchParams();
  if (params.sort) {
    ([] as string[]).concat(params.sort).forEach((s) => sp.append('sort', s));
  }
  if (params.pagination?.page) sp.set('pagination[page]', String(params.pagination.page));
  if (params.pagination?.pageSize) sp.set('pagination[pageSize]', String(params.pagination.pageSize));
  if (params.pagination?.withCount !== undefined) {
    sp.set('pagination[withCount]', String(params.pagination.withCount));
  }
  if (params.populate) sp.set('populate', JSON.stringify(params.populate));
  if (params.fields) params.fields.forEach((f) => sp.append('fields', f));
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
