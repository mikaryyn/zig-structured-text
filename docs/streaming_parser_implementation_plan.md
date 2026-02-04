# Zig streaming element parser + normalization pipeline (HTML/XML/XHTML) — implementation plan

## Goals
- Provide a **single streaming API** that accepts **UTF-8 bytes** incrementally.
- Layer 1 is a **direct “raw element parser”** (no separate public tokenizer stage).
- Layer 2 is a **normalization/conformance stage** that turns raw events into a stream with strong invariants.
- Support:
  - **XML** (incl. XHTML when treated as XML)
  - **HTML** (at least a strict subset first; optionally HTML5-conforming later)

---

## Terminology (used consistently)
- **Raw events**: reflect what appears in the source with minimal interpretation.
- **Normalized events**: conform to the invariants promised to downstream consumers.

> Internally you may still implement tag-level scanning, but you won’t expose “tokens” as a public type.

---

## Public API shape

### Types
- `ParserMode = enum { html, xml, auto }`
- `Origin = enum { explicit, implied }`

### Events
Define a single event union used end-to-end:
- `ElementStart { name: []const u8, origin: Origin }`
- `Attribute { name: []const u8, value: []const u8 }` *(emitted immediately after its `ElementStart`)*
- `ElementEnd { name: []const u8, origin: Origin }`
- `Text { bytes: []const u8 }` *(optionally decoded text later)*
- `Comment { bytes: []const u8 }` *(optional)*
- `Doctype { name: []const u8, ... }` *(optional; mainly HTML)*
- `ProcessingInstruction { target, data }` *(optional; XML)*
- `Cdata { bytes }` *(optional; XML)*
- `Error { kind, message, location? }`
- `NeedMoreInput`
- `EndOfStream`

### Attribute ordering
- Attributes are emitted as standalone `Attribute` events **immediately after** the corresponding `ElementStart`.
- Attribute events are associated with the **most recent** `ElementStart` that has not yet been closed by another `ElementStart` or an `ElementEnd`.

### Streaming control
- `Attribute { name: []const u8, value: []const u8 }`

### Streaming control
- `feed(bytes: []const u8) !void`
- `nextEvent() !Event`
- `finish() !void` (signals EOF; enables end-of-file handling)

### Ownership/lifetime contract
Pick one (write it in docs and enforce it):
1. **Borrowed slices**: event slices valid until the next `nextEvent()` call.
2. **Arena-backed**: event slices valid until `resetArena()` or parser drop.

**Recommendation**: arena-backed for ergonomics; add `reset()` to reuse memory.

---

## Layering and names

### Layer 1: `RawElementParser`
**Responsibilities**
- Incremental UTF-8 byte ingestion (no assuming chunk boundaries align with syntax)
- Low-level scanning + state machines for:
  - XML markup constructs
  - HTML markup constructs (including rawtext/script/style/rcdata handling)
- Emits **raw** `ElementStart/End/Attribute/Text/...` events with `origin = .explicit`
- Minimal validation:
  - XML: reject illegal characters early, basic name parsing.
  - HTML: accept broader name/attr syntax.

**Non-goals**
- No balancing / nesting repairs
- No implied elements
- No “browser-like” table/adoption agency behavior

### Layer 2: `ElementNormalizer`
Use a common interface:
- `pub fn push(event: Event) !void`
- `pub fn nextEvent() !Event`

Provide implementations:
- `XmlNormalizer` (well-formedness + namespaces optional)
- `HtmlNormalizer` (strict subset first; optional upgrade to HTML5-conforming)

This stage may emit `origin = .implied` starts/ends if it performs implicit closures/insertions.

---

## Recommended incremental roadmap

### Phase 0 — Test harness & scaffolding
- Create a property-testable harness:
  - `feed` random chunk boundaries
  - compare outputs for whole-buffer vs chunked feed
- Golden file tests for representative inputs.
- Fuzz targets (libFuzzer/afl) focusing on chunk boundaries.

### Phase 1 — Core infrastructure
1. **InputBuffer**
   - ring buffer or growable buffer with read cursor
   - methods: `peek()`, `consume(n)`, `consumeWhile()`, `mark()`, `resetToMark()`
   - support “need more input” without losing partial state
2. **UTF-8 handling**
   - If you operate on bytes for parsing markup, you only need to ensure you don’t split codepoints when emitting text (optional).
   - Implement safe text emission that can defer incomplete UTF-8 sequences until more input arrives.
3. **EventQueue**
   - fixed-size ring + fallback allocator, or a simple `ArrayList(Event)` plus indices
   - `nextEvent()` pops from queue; parser fills queue during scanning
4. **Allocator strategy**
   - Use an arena for per-event strings (names, attr names/values, text slices)
   - Provide `reset()` to clear state and arena

### Phase 2 — `RawElementParser` for XML (minimum)
Implement a streaming XML subset first (no DTD):
- Markup recognition:
  - `<name ...>` start
  - `</name>` end
  - text outside markup
  - `<!-- comment -->`
  - `<?pi ...?>`
  - `<![CDATA[...]]>`
- Attribute parsing:
  - `name="value"` and `name='value'` only (start strict)
  - entity decoding optional at first (keep raw `&...;`)
- Errors:
  - malformed markup, unterminated constructs, invalid name chars
- `finish()`:
  - if inside a construct, emit `Error` or finalize based on mode

Deliverable: XML inputs produce a stable raw event stream.

### Phase 3 — `XmlNormalizer` (well-formedness)
- Maintain a stack of open element names
- Invariants produced:
  - properly nested elements
  - matched start/end names
  - no duplicate attributes on the same element
  - optional: namespace resolution, `xml:space` propagation
- Policy:
  - On mismatch: emit `Error` and choose either fail-fast or recover-by-closing (config)

Deliverable: normalized stream suitable for SAX-like consumers.

### Phase 4 — Extend `RawElementParser` to HTML-compatible scanning
Implement HTML-ish parsing rules in layer 1 (still “raw”):
- Start/end tags, attributes with:
  - unquoted values
  - boolean attributes
  - missing value (`disabled`)
  - flexible whitespace
- Case behavior:
  - do **not** normalize in layer 1; keep source spelling (or optionally store both raw + folded)
- Rawtext/RCDATA/script/style tokenizer states (internal):
  - after emitting `<script>` start, switch to script-data scanning until a valid `</script...>` appears
  - same for `style`/`textarea`/`title`
- Comments and doctype:
  - parse `<!-- ... -->`
  - parse `<!doctype ...>` into a doctype event (optional)

Deliverable: HTML inputs stream raw element-like events without full recovery.

### Phase 5 — `HtmlNormalizer` strict subset (KISS)
Start with a “strict-ish HTML” normalizer that provides useful invariants without full HTML5:
- Maintain open element stack
- Implement a small set of implicit end-tag rules (configurable):
  - close `<p>` on block-level starts
  - close `<li>` on new `<li>`
  - close `<dt>/<dd>` on new `<dt>/<dd>`
  - close headings when a new heading starts
- Enforce nesting for everything else (emit `Error` on mismatch)
- Normalize names to lowercase in normalized output
- Emit attributes as `Attribute` events immediately following their `ElementStart`
- Attribute normalization:
  - dedupe attributes per element (keep first/last based on config)
  - normalize attribute names by mode
  - trim/normalize whitespace in unquoted values optionally
- Text normalization options:
  - optionally coalesce adjacent text nodes

Deliverable: practical HTML stream for controlled inputs.

### Phase 6 — Optional: upgrade `HtmlNormalizer` toward HTML5-conforming
If you need browser-like results, incrementally add:
- Insertion modes (head/body/table/select)
- Table foster parenting handling (may require buffering some text)
- Active formatting elements + adoption agency algorithm

Keep it streaming:
- avoid building a DOM; only store the minimal stacks/lists the algorithms require
- buffer only when necessary for correct emission

---

## Handling `auto` mode
Prefer explicit mode from the caller; but if you support `auto`:
- Sniff a small prefix (e.g., up to N bytes):
  - if `<?xml` appears early → XML
  - if `<!doctype` / `<html` / common HTML patterns → HTML
  - otherwise default per config
- Once decided, lock the mode.

---

## Configuration knobs (keep them explicit)

### Parser options
- `max_name_len`, `max_attr_len`, `max_text_chunk`
- `emit_comments`, `emit_doctype`, `emit_pi`, `emit_cdata`
- `borrowed_slices` vs `arena_backed`

### Normalizer options
- `fail_fast: bool`
- `coalesce_text: bool`
- `html_implicit_rules: enum { none, basic, html5 }`
- `attr_dedupe_policy: enum { keep_first, keep_last, error }`
- `case_policy_html: enum { preserve, lowercase }` *(recommend lowercase in normalized output)*

---

## Memory & performance plan
- Use a **single arena** for event payloads; clear it on `reset()`.
- Keep small stacks as `ArrayListUnmanaged([]const u8)` with preallocation.
- Emit text in bounded chunks to avoid huge allocations.
- For rawtext/script scanning, avoid copying by slicing from the input buffer when possible; copy only if data spans buffer compaction.

---

## Testing strategy

### Correctness
- Round-trip invariants:
  - normalized output must be properly nested
  - XML normalized must be well-formed
  - HTML normalized must satisfy configured implicit rules
- Chunk-boundary tests:
  - feed 1 byte at a time and compare to whole-buffer parse

### Fuzzing
- Fuzz `feed` chunk sizes and content
- Fuzz malformed markup; ensure no panics, no OOB, and bounded memory growth

### Golden cases
- XML: mixed content, attributes, comments, cdata, PI
- HTML: unquoted attrs, boolean attrs, `<script>` with `<` characters, malformed nesting, implicit closures

---

## Practical implementation notes in Zig
- Prefer `union(enum)` for `Event`.
- Keep parser state machines as `enum` + `switch`.
- Use `std.ascii` helpers for HTML folding; use stricter Unicode/name checks for XML as a later enhancement.
- Provide `Error` values with a small enum kind + optional position info.

---

## Deliverables checklist
1. `RawElementParser` (XML) + tests
2. `XmlNormalizer` + tests
3. `RawElementParser` (HTML scanning states) + tests
4. `HtmlNormalizer` basic implicit rules + tests
5. Optional HTML5 upgrades (tables/formatting) gated by feature flags

