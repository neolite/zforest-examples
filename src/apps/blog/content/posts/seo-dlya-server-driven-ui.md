---
title: SEO для server-driven UI: canonical, OG, JSON-LD
date: 2026-11-15
author: Команда ZBlog
tags: seo, zmeta, meta
description: Как zblog собирает SEO-head постранично — уникальные title, canonical, Open Graph article:*, BlogPosting JSON-LD, sitemap и robots.
---

## Проблема

Server-driven UI обычно думает о DOM-патчах и SSE, а не о поисковиках. Но блог — это в первую очередь SEO-задача: каждая страница должна отдать корректный `<head>` ещё в первом SSR-ответе, без клиентского JS.

## Решение: HeadSpec на страницу

В zmeta страница может объявить `head()` → `HeadSpec{title, extra, lang}`. Zblog использует это на полную:

- **title** уникален: `«Заголовок поста — ZBlog»`, на страницах пагинации — `«Страница 2 из 3 — ZBlog»`.
- **canonical** абсолютный, из `site_url`: `/` для первой страницы, `/?page=2` — самоссылающийся для второй.
- **meta description** — из frontmatter или авто-excerpt ~160 символов.

## Open Graph и article:*

На постах `og:type=article` плюс `article:published_time`, `article:modified_time`, `article:section` (первый тег), `article:author`. `og:locale=ru_RU`, `og:site_name=ZBlog` — везде.

## JSON-LD

- Индекс: `Blog` + `ItemList` видимых постов (position/url/name).
- Пост: `BlogPosting` с headline, description, datePublished/dateModified, author (Person), mainEntityOfPage, keywords из тегов, publisher (Organization).

JSON сериализуется руками в `plugins/seo.zig` — без зависимостей, с экранированием `<`/`>`/`&` → `\uXXXX`, чтобы payload не мог вырваться из `<script>`.

## Вне <head>

- `/sitemap.xml` — все посты и теги с lastmod.
- `/robots.txt` — `Allow: /` + ссылка на sitemap.
- `/rss.xml` — полный архив с `content:encoded`.

## Проверка

Smoke-тесты смотрят на наличие `lang="ru"`, `<article>`, `<time datetime>`, JSON-LD и OG-тегов в ответе — всё это проверяется curl'ом без браузера.
