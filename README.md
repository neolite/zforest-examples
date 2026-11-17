# zforest-examples

Example apps for [zforest](https://github.com/neolite/zforest) —
server-driven UIs in Zig: the `zefx` reactive graph core plus `forest`,
a fine-grained DOM patch layer, served by a minimal `std.http` server
with a vanilla JS patch client. This repo holds the apps; the framework
itself lives in the sibling `zforest` repo.

Five apps share the transport:

- **`zforest`** — the Todo demo (per-session view state; todos persist
  to SQLite keyed by a `ztd` client cookie).
- **`zboard`** — an anonymous message board (static boards, threads,
  nested tree comments) over a shared SQLite-backed model.
- **`zmon`** — a live ops dashboard (mock request stream, windowed
  rps/error/latency stats, 384-line request-log firehose, inject +
  storm buttons, traffic sliders, SVG sparklines) on **fine-grained
  live bindings**: the view tree is built once per session and every
  bound leaf subscribes to its store, so updates emit patch ops with
  no rebuild+diff (`forest.bindTree`).
- **`zcar`** — a service-booking demo (brand → model → year cascade,
  vehicle specs, service catalogue by category, context upsells, combo
  discounts, booking form + history) — exercises keyed lists and
  conditional subtrees on the diff path.
- **`zmeta-demo`** — the `zmeta` meta-framework demo: file-based
  routes, typed params, generated action dispatch, `Session(Deps)`
  skeleton.

## Dependency on zforest

This repo consumes the framework as a Zig package dependency:

```zig
// build.zig.zon
.zforest = .{ .path = "../zforest" },
```

The `zforest` repo must be checked out as a **sibling directory**
(`../zforest`). Apps import the framework's named modules — `zefx`,
`forest`, `zserver`, `zmeta`, `zdb` — which `build.zig` pulls from the
dependency via `dep.module(name)`, preserving type identity across the
boundary. `zdb` carries the vendored sqlite3 amalgamation, so the
sqlite-linked apps (`zforest`, `zboard`) need nothing extra.

A git-URL dependency (`git+https://…`) is a possible future option once
the framework stabilizes its package layout.

## Run

```sh
zig build        # produces zig-out/bin/{zforest,zboard,zmon,zcar,zmeta-demo}
zig build run    # serves the todo app on http://127.0.0.1:8080
zig build run-board 8081 127.0.0.1 board.db  # board on :8081, file db
zig build run-mon 8082 127.0.0.1             # dashboard on :8082
zig build run-car 8083 127.0.0.1             # booking demo on :8083
zig build run-demo 8084 127.0.0.1            # zmeta demo on :8084
./zig-out/bin/zforest [port] [bind-ip] [db-path]  # db-path default "zforest-todos.db"
./zig-out/bin/zboard   [port] [bind-ip] [db-path]   # db-path default ":memory:"
./zig-out/bin/zmon     [port] [bind-ip]
./zig-out/bin/zcar     [port] [bind-ip]
./zig-out/bin/zmeta-demo [port] [bind-ip]
zig build test   # all app test targets
```

## Apps

### zboard

Routes: `/` (board list + latest posts), `/b/<slug>` (post form + keyed
post list), `/t/<post>` (post card + comment form + nested comment tree),
`/t/<post>/c/<comment>` (breadcrumbs + focused comment subtree). Unknown
paths and dangling ids return 404.

- `src/apps/board/entities/model.zig` — `BoardModel`: static board
  whitelist, in-memory post/comment/user arrays, write-through SQLite
  inserts, one shared `next_id` across posts and comments (display
  `#N`), and `global_seq`, an atomic bumped on every mutation.
- `src/apps/board/` — the zmeta app dir (FSD layers): `app.zig`
  (session/deps + action handlers) + `groups.zig` (render groups) at
  the app root, `entities/` (model + accounts), `features/` (auth),
  `shared/` (view components + markdown), `pages/` file routes (`/`,
  `/b/<slug>`, `/t/<post>`, `/t/<post>/c/<comment>`). Every browser
  session still owns an
  isolated zefx graph + DOM state, but all sessions share
  the one model: each SSE worker calls `syncPull()` every 50 ms, which
  re-renders when `global_seq` moved and publishes the resulting patch
  batch — so a post in one tab appears live in every other tab (and a
  no-op diff for sessions on unrelated routes).
- Identity is anonymous: the first `POST /action` without a `zfxu`
  cookie mints a `users` row and returns `Set-Cookie: zfxu=<token>`
  (one-shot — later POSTs don't re-send it); posts display as
  `Anon#<base36(rownum)>`, stable across restarts.
- Inline replies mount via `when("w-rep-N")` anchors inside each comment
  row; `reply_to` is per-session, cleared on navigation and after a
  successful comment.

File databases persist everything: `zboard 8081 127.0.0.1 board.db`
restarts with posts/comments/users intact (`:memory:` is ephemeral).
See [docs/zboard.html](docs/zboard.html) for the original design doc
and [docs/adr/](docs/adr/) for architecture decision records.

### zforest (todo)

`zig build run` serves the TodoMVC app on `127.0.0.1:8080` with todos
persisted to `zforest-todos.db` in the cwd (`zforest [port] [bind-ip]
[db-path]`; `:memory:` opts back into the ephemeral demo). Persistence
is keyed by a `ztd` client cookie — minted on the first `POST /action`
— not by the session cookie, so todos survive session eviction (32-cap
FIFO), server restarts, and are shared by tabs of the same browser.
Rows write through on every mutation; a session lazy-loads its client's
rows on first contact. `src/apps/todo/store.zig` holds the `TodoStore`
(schema + prepared statements); `zdb` (from the framework) is the shared
sqlite wrapper.

### zmeta apps

`zboard`, `zmon`, `zcar`, and `zmeta-demo` are all `zmeta` apps:
file-based routes under `pages/`, an `actions.zig` manifest, generated
`gen/routes.zig` + `gen/actions.zig`, and a `Session(Deps)` skeleton.

```sh
zig build gen        # regenerate src/apps/*/gen/*.zig (idempotent, checked in)
zig build new-app -- my_app   # scaffold src/apps/my_app/ + regenerate
```

After scaffolding, register the exe in `build.zig` (module +
`addExecutable` + install/run/test steps — `zig build new-app` prints
the snippet). Framework-side docs live in the `zforest` repo:
`docs/meta-framework.md` (the meta-framework spec) and
`docs/getting-started.md` (tutorial).
