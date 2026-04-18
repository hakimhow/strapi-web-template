import type { APIRoute } from 'astro';
import { strapiGet, type StrapiList } from '@/lib/strapi';

export const prerender = false;

interface Article { title: string; slug: string; excerpt?: string; }

export const GET: APIRoute = async ({ url }) => {
  const q = url.searchParams.get('q')?.trim() ?? '';
  if (!q) return new Response(JSON.stringify({ results: [] }), { headers: { 'content-type': 'application/json' } });

  try {
    // Strapi v5 filter: $containsi 不区分大小写；$or 仍然支持
    const res = await strapiGet<StrapiList<Article>>('/articles', {
      filters: { $or: [{ title: { $containsi: q } }, { excerpt: { $containsi: q } }] } as never,
      pagination: { pageSize: 20 },
      sort: 'publishedAt:desc',
    });
    // v5 扁平响应：直接展开
    const results = res.data.map((d) => ({
      id: d.id,
      documentId: d.documentId,
      title: d.title,
      slug: d.slug,
      excerpt: d.excerpt,
    }));
    return new Response(JSON.stringify({ results }), {
      headers: { 'content-type': 'application/json', 'cache-control': 'public, max-age=30' },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
};
