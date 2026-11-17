---
title: RSS, sitemap и robots.txt без фреймворка
date: 2026-11-12
author: Команда ZBlog
tags: rss, seo, feeds
description: Три raw-эндпоинта zblog — RSS 2.0 с content:encoded, sitemap.xml и robots.txt — как они устроены в zmeta.
---

## Raw-эндпоинты zmeta

Файл с точкой в последнем сегменте (`rss.xml.zig`, `sitemap.xml.zig`, `robots.txt.zig`) становится raw-эндпоинтом: он экспортирует `api() → []const u8` и опционально `content_type`. Никакого HTML-layout, никакого forest-дерева — чистый текст/XML.

## RSS 2.0

`plugins/rss.zig` собирает канал и items:

- `title`, `link`, `description`, `language=ru`, `lastBuildDate` (RFC-822 из ISO-даты поста).
- На item: `title`, `link`, `guid`, `pubDate`, `description`, `<category>` на каждый тег.
- `content:encoded` — полный HTML статьи в CDATA (с защитой от `]]>` внутри контента) — поэтому объявлен `xmlns:content`.
- `atom:link rel="self"` — canonical URL фида.

```xml
<rss version="2.0" xmlns:content="..." xmlns:atom="...">
  <channel>…</channel>
</rss>
```

## sitemap.xml

`<urlset>` из всех индексируемых URL: `/`, `/about`, каждый `/post/<slug>` (с `<lastmod>` = дате поста) и каждый `/tag/<tag>`. Черновики (`draft: true`) не попадают в sitemap, потому что не загружаются вообще.

## robots.txt

Минимальный, но корректный: `User-agent: *`, `Allow: /`, `Sitemap: <site_url>/sitemap.xml`. Без `content_type` сервер отдаёт `text/plain` по умолчанию.

## Почему это важно для SEO

RSS ускоряет индексацию и питает агрегаторы, sitemap — это прямой список для краулера, robots — правила обхода. Все три строятся из одного источника правды — загруженных markdown-файлов — поэтому не могут разойтись с сайтом.
