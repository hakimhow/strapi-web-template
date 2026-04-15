import type { APIRoute } from 'astro';
import { strapiGet } from '@/lib/strapi';

export const prerender = false;

interface StrapiList<T> { data: Array<{ id: number; attributes: T }>; }
interface Article { title: string; slug: string; excerpt?: string; }

export const GET: APIRoute = async ({ url }) => {
  const q = url.searchParams.get('q')?.trim() ?? '';
  if (!q) return new Response(JSON.stringify({ results: [] }), { headers: { 'content-type': 'application/json' } });

  try {
    // Strapi v4 filter: $containsi (case-insensitive)
    const res = await strapiGet<StrapiList<Article>>('/articles', {
      filters: { $or: [{ title: { $containsi: q } }, { excerpt: { $containsi: q } }] } as never,
      pagination: { pageSize: 20 },
      sort: 'publishedAt:desc',
    });
    const results = res.data.map((d) => ({ id: d.id, ...d.attributes }));
    return new Response(JSON.stringify({ results }), {
      headers: { 'content-type': 'application/json', 'cache-control': 'public, max-age=30' },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
};
