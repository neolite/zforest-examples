# Repository Guidelines

`zforest-examples` holds the **example apps** for the
[zforest](https://github.com/neolite/zforest) framework. The framework
(`zefx` reactive core, `forest` DOM patch layer, `zmeta` meta-framework,
`zserver` HTTP/SSE transport) lives in the sibling repo checked out at
`../zforest` — this repo only carries app code and build wiring.

## Project Structure & Module Organization

- `src/apps/<name>/` — one self-contained app per directory:
  - `main.zig` — exe entry point (`pub fn main` + test block)
  - `app.zig` — session/deps + action handlers (zmeta apps)
  - `zmeta.zig` — shim re-exporting the `zmeta` module (`@import("zmeta")`)
  - `actions.zig` — action-name manifest for codegen
  - `pages/` — file-based routes (`[name]` segments → typed params)
  - `gen/routes.zig` + `gen/actions.zig` — generated, checked in
  - FSD layer dirs as needed: `entities/`, `features/`, `shared/`
- Apps: `todo` (exe `zforest`, sqlite via `zdb`), `board` (exe `zboard`,
  sqlite via `zdb`), `mon` (exe `zmon`, live bindings, libc), `car`
  (exe `zcar`), `zmeta_demo` (exe `zmeta-demo`), `blog` (exe `zblog`,
  read-only markdown CMS + SEO, no sqlite).
- `plugins/*.zig` — compile-time Zig plugin modules (`html`,
  `markdown`, `seo`, `rss`) imported by apps as named modules
  (`zplug_*`); declared via `createModule` in `build.zig` with
  `forest` injected for type identity. Each plugin gets its own
  `addTest` target — plugin-module `test` blocks do not run inside
  app test binaries.
- `build.zig` — consumes the framework via `b.dependency("zforest")`
  and `dep.module("zefx"|"forest"|"zserver"|"zmeta"|"zdb")`; each app
  gets a `createModule` rooted at its `main.zig`. `gen`/`new-app`
  steps root std-only tool modules at `dep.path("src/zmeta/*.zig")`
  with `setCwd(b.path("."))` so codegen scans THIS repo's `src/apps/`.

## Architecture notes

- Apps may only reach the framework through the named modules — the
  dependency arrow never points back. Type identity is preserved
  because every exe imports the dep's own `*Module` objects.
- `zdb` (framework-side) carries the vendored sqlite3 amalgamation +
  C flags; only sqlite-using apps (`zforest`, `zboard`) get the import.
- Framework docs: `../zforest/ARCHITECTURE.md`, `../zforest/docs/`.
  App-specific docs live here under `docs/`.

## Build, Test, and Development Commands

- `zig build`: compile and install the executables (`zforest`, `zboard`,
  `zmon`, `zcar`, `zmeta-demo`, `zblog`) — requires `../zforest`
  checked out.
- `zig build run` / `run-board` / `run-mon` / `run-car` / `run-demo` /
  `run-blog`: run an app (args pass through to the exe; `zblog` takes
  `[port] [bind-ip] [content-dir]`).
- `zig build test`: run the six app test targets plus one per plugin
  module under `plugins/`.
- `zig build gen`: regenerate `src/apps/*/gen/*.zig` (idempotent).
- `zig build new-app -- <name>`: scaffold `src/apps/<name>/` then regen.
- `zig fmt src/**/*.zig build.zig`: format before committing.

## Coding Style & Naming Conventions

- `zig fmt` is the source of truth (4-space indent).
- PascalCase types, camelCase functions; lowercase snake filenames.
- Keep public API in the framework repo; apps stay self-contained.

## Testing Guidelines

- Zig built-in `test "..."` blocks colocated in app files; each app's
  `main.zig` test block pulls in its module graph.
- Run `zig build test` before committing.

## Commit & Pull Request Guidelines

- Concise, imperative commit subjects.
- PRs: problem statement, behavior summary, `zig build test` evidence.
