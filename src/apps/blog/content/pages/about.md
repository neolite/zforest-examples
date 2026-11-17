---
title: О блоге
date: 2026-11-01
description: ZBlog — read-only блог о zforest, zmeta и server-driven UI на Zig. Markdown-файлы как CMS, SEO из коробки.
---

ZBlog — демонстрационное приложение репозитория `zforest-examples`: полностью read-only блог, построенный на мета-фреймворке **zmeta** и файловом транспорте **zserver**.

## Что внутри

- **File-based роутинг** — страницы это файлы в `pages/`, роуты генерируются `zig build gen`.
- **Markdown-CMS** — посты в `content/posts/*.md` с frontmatter, статические страницы в `content/pages/`.
- **SEO-first** — уникальные title, canonical, Open Graph, JSON-LD (Blog/ItemList/BlogPosting), sitemap.xml, robots.txt, RSS.
- **Compile-time плагины** — `plugins/markdown.zig`, `plugins/seo.zig`, `plugins/rss.zig`, `plugins/html.zig` — обычные Zig-модули, импортируемые относительными путями.

## Принципы

1. **Сервер — источник правды.** Весь HTML рендерится SSR; клиентского JS нет вообще.
2. **Контент — это файлы.** Git-история вместо CMS, деплой — копирование каталога.
3. **Безопасность по умолчанию.** Markdown не пропускает raw HTML; весь вывод экранируется.
4. **Семантика имеет значение.** `<article>`, `<time datetime>`, `<nav aria-label>`, один h1 на страницу.

## Контент

Статьи выходят нерегулярно — по мере появления тем. Все посты на русском, метки — латинскими slug'ами (`zig`, `seo`, `rss`).
