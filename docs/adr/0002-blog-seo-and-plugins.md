# zblog: markdown-file CMS, compile-time plugins, SEO-first `<head>`

**Status:** landed

`zblog` (`src/apps/blog/`, exe `zblog`) is a read-only, SEO-focused
blog. Three decisions define it: content is Markdown files rather
than a database, reusable capabilities live in compile-time Zig plugin
modules under `plugins/`, and every page owns its SEO metadata through
the `zmeta` `HeadSpec` hook rather than shared middleware.

## Decision

1. **Markdown files are the CMS.** Posts live in
   `src/apps/blog/content/posts/*.md`, static pages in
   `content/pages/*.md`, each with a small YAML-subset frontmatter
   (`title`, `date`, `author`, `tags`, `description`, `slug`,
   `draft`) parsed by `content.zig`. Content loads once at startup;
   `draft: true` rows are parsed but excluded. There is no write path
   at all — no comments, no admin, no SQLite — which removes
   migrations, locking, and backup concerns for a publishing surface.

2. **Plugins are compile-time Zig modules.** `plugins/{html,markdown,
   seo,rss}.zig` are ordinary Zig files turned into named modules
   (`zplug_html`, `zplug_markdown`, `zplug_seo`, `zplug_rss`) by
   `build.zig` `createModule` calls; the blog module lists them in
   `.imports`. Nothing is dynamically loaded and nothing is
   framework-side — the dependency arrow stays examples → framework.
   `forest` is injected into each plugin module so `forest.Node`
   trees keep type identity with the app's. Each plugin also gets its
   own `addTest` target: plugin modules are separate Zig modules, so
   their `test` blocks do not run inside the app test binaries.

3. **SEO metadata is page-owned.** Each page's `head()` hook returns
   a `zmeta.HeadSpec` whose `extra` carries canonical link, meta
   description, Open Graph (`website`/`article`), Twitter card,
   pagination `rel=prev/next`, and JSON-LD (`Blog`, `BlogPosting`,
   `WebPage`, `Person`, `Organization`). `plugins/seo.zig` is the
   escaping boundary: attribute values are HTML-escaped, JSON-LD
   strings get script-safe `\uXXXX` escaping for `<`/`>`/`&`. RSS,
   sitemap, and robots are ordinary file-routed raw endpoints
   (`pages/rss.xml.zig` → `/rss.xml` with
   `content_type = "application/rss+xml"`, etc.) rendered from the
   same in-memory content.

4. **Semantic HTML without client JS.** `plugins/html.zig` emits
   escaped raw elements for tags `forest.Tag` lacks (`article`,
   `nav`, `header`, `time`, `ol`, `del`, `h4`–`h6`);
   `plugins/markdown.zig` renders Markdown to `forest.Node` trees
   (headings with slug `id`s + dedup, lists, tables, fenced code,
   blockquotes, strikethrough, Cyrillic transliteration in slugs).
   Post pages get `<article>`, `<time datetime>`, a `<details>` TOC
   when ≥2 headings, and tag links — all SSR, zero client JavaScript.

## Considered options

- **SQLite/content API like zboard** — rejected for a blog: posts
  are authored as files, versioned with the repo, and the app is
  deliberately read-only; a database buys nothing and costs a write
  path, migrations, and `zdb` linkage.
- **Framework-level plugin mechanism** — rejected: one app does not
  justify generalizing; `plugins/` + named modules is ~40 lines of
  `build.zig` and keeps the framework untouched.
- **Shared layout-level `<head>` assembly** — rejected: the page
  knows its canonical URL, type (article vs website), dates, and
  tags better than any layout; `HeadSpec.extra` is the framework's
  intended per-page escape hatch and keeps SEO logic next to the
  route that owns it.
- **Client-side search/highlighting** — deferred: `?q=` search is a
  plain GET form over title/body/tags server-side; no JS shipped.

## Consequences

- Adding a post is `git`-able file authoring + redeploy; there is no
  runtime content mutation to test or secure.
- `site_url` is a compile-time constant (`https://blog.example.com`
  placeholder in `app.zig`) — canonical/OG/RSS/sitemap URLs all
  derive from it; a real domain is a one-line change at deploy time.
- Markdown coverage is a documented subset (see `plugins/markdown.zig`
  header): ATX headings, paragraphs, emphasis/strong/code/links/
  images/strikethrough, blockquotes, fenced code with language
  class, ordered/unordered nested lists, pipe tables, thematic
  breaks — plus Cyrillic slug transliteration. Inline HTML stays
  escaped (no raw-HTML passthrough).
- Pagination emits `rel=prev/next` and self-referencing canonicals;
  `?page=1` canonicalizes to `/`.
- Deployment is intentionally deferred — local execution via
  `zig build run-blog` is the supported mode for now.
