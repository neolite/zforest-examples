---
title: Zig 0.17 в бою: Io.Writer и Allocating
date: 2026-10-28
author: Команда ZBlog
tags: zig
description: Практические заметки по Zig 0.17.1 — std.Io.Writer.Allocating для строк, ArenaAllocator для per-render памяти, новый std.http.
---

## Почему 0.17

Zig 0.17.1 — свежий stable с переработанным `std.Io`. Старый `std.ArrayList(u8).writer()` ушёл, на его место пришёл `std.Io.Writer.Allocating` — writer, который сам управляет буфером.

## Паттерн Allocating

В plugins/ почти везде одна и та же идиома:

```zig
var aw: std.Io.Writer.Allocating = .init(a);
const w = &aw.writer;
w.writeAll("<meta name=\"description\" content=\"") catch @panic("OOM");
forest.escapeHtmlInto(w, value) catch @panic("OOM");
w.writeAll("\"/>\n") catch @panic("OOM");
return aw.toOwnedSlice() catch @panic("OOM");
```

Никаких `allocPrint` для составных строк — writer пишет прямо в арену, результат один непрерывный срез.

## Память: арены на запрос

Каждый запрос рендерится в свежем `ArenaAllocator` — markdown, JSON-LD, SEO-строки живут до конца рендера и освобождаются оптом. Контент же загружается один раз в отдельную арену, которая живёт всю жизнь процесса.

## Что не хватило

- `std.mem.sort` на месте, но `std.sort.pdq` тоже ок.
- `++` для конкатенации срезов работает только если срез comptime-known — для runtime-строк только writer/allocPrint.
- Именованные модули из `build.zig.zon` (`dep.module(...)`) — единственный чистый способ сохранить type identity между exe и фреймворком.
