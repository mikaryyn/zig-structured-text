# zig-structured-text

Low-resource parsing and processing utilities for structured text documents, designed for streaming and embedded use.

This package aims to support:
- Markdown (tokenization / lightweight parsing primitives)
- EPUB (planned; ZIP/container plumbing is present, full implementation is WIP)
- A custom compact binary format for structured text (planned)
- Markup parsing utilities used by EPUB/XHTML pipelines (streaming XML/HTML-style event parsing)

## Status (WIP)

This repository is work-in-progress and the API is not stable yet.

Currently implemented:
- `src/markdown/tokenizer.zig`: a streaming-ish text/word tokenizer (UTF-8 aware, emits word/line/paragraph breaks)
- `src/xhtml-parser/raw_element_parser.zig`: a small streaming element/text event parser (currently XML mode only)
- `src/xhtml-parser/xml_sanitizer.zig`: a streaming XML well-formedness sanitizer/normalizer for the raw event stream

Planned / incomplete:
- `src/epub/`: EPUB container + content pipeline
- HTML parsing/normalization modes in the markup parser
- Custom compact binary format tooling

## Goals

- Stream input incrementally (don’t require the full document in memory).
- Keep memory use predictable and low (small buffers, explicit limits, allocator-aware).
- Prefer event streams (SAX-like) over DOM construction.
- Be usable in constrained environments (embedded, low RAM).

## Getting started

### Add as a dependency

This repo exposes a Zig module named `structured_text` (see `build.zig` and `build.zig.zon`).

In your consumer project’s `build.zig`, add the dependency and module:

```zig
const structured_text_dep = b.dependency("structured_text", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("structured_text", structured_text_dep.module("structured_text"));
```

Then in code:

```zig
const st = @import("structured_text");
```

### Run tests

```sh
zig build test
```

## Naming conventions (Zig)

Use `lowerCamelCase` for all functions, except functions that return a type (Zig), which use `PascalCase`.

## API overview (current)

### Markdown

- `st.md.tokenizer` (`src/markdown/tokenizer.zig`)
  - `TxtByteReader`: buffered byte reader with offsets
  - `TxtTokenizer.next()`: emits `TxtToken` (`Word`, `LineBreak`, `ParagraphBreak`, `Eof`)

### Markup (XML/XHTML building blocks)

- `st.markup.RawElementParser` (`src/xhtml-parser/raw_element_parser.zig`)
  - `feed(bytes)`, `finish()`, `nextEvent()`
  - Emits an `Event` stream (`ElementStart`, `Attribute`, `ElementEnd`, `Text`, …)
  - Currently implements `ParserMode.xml` only
- `st.markup.XmlSanitizer` (`src/xhtml-parser/xml_sanitizer.zig`)
  - `push(event)`, `nextEvent()`, `finish()`
  - Enforces basic XML well-formedness invariants (single root, proper nesting, no duplicate attrs, etc.)

## Project structure

- `src/root.zig`: module entry point (exports `md` and `markup`)
- `src/markdown/`: Markdown-related primitives (currently a tokenizer)
- `src/xhtml-parser/`: streaming XML/markup parser + sanitizer (foundation for XHTML/EPUB work)
- `src/epub/`: EPUB pipeline (placeholder; WIP)
- `libs/`: vendored third-party C code (currently `miniz` for ZIP/deflate functionality, intended for EPUB containers)
- `docs/`: design/implementation notes (see `docs/streaming_parser_implementation_plan.md`)

## Roadmap notes

If you’re evaluating this repo today (February 5, 2026), treat it as an experimental foundation:
- Expect breaking API changes as the EPUB pipeline and binary format land.
- The long-term direction is a streaming document pipeline that can ingest Markdown/EPUB/binary sources and produce a normalized event stream suitable for rendering, indexing, or transformation on low-resource devices.
