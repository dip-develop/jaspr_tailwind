# Changelog

## 0.3.7 — Tailwind CSS v4 support

Adds Tailwind CSS **v4** support. Based on `0.3.6` (commit `4d03ae1`), which
targets Tailwind CSS **v3**.

The package name and the `build.yaml` builder identity are unchanged
(`import: "package:jaspr_tailwind/builder.dart"`, factory `buildStylesheet`), so
this is a drop-in upgrade: no consumer changes beyond the version constraint.

The README already documented `@import "tailwindcss";` as the v4 entry point,
but the builder did not implement it — it passed `--content`/`--config`, which
v4 removed. This release makes the documented behaviour real.

### Behavioural changes

1. **`@source` injection replaces `--content` / `--config`.**
   Tailwind v4 removed both CLI flags and the `@tailwind` directives. Source
   globs are now emitted as absolute `@source` directives appended to the
   stylesheet before it is handed to the CLI, because v4 resolves `@source`
   relative to the stylesheet file and the compiled copy lives in a temp
   directory. Absolute paths anchored at the package root are the only form that
   resolves reliably.

2. **The `Process.run` result is now checked.**
   Upstream discarded the result, so every Tailwind failure was silent and a
   build could "succeed" while emitting an unstyled stylesheet. The exit code,
   output-file existence and the captured stdout/stderr are all inspected, and a
   missing `tailwindcss` binary is reported as an actionable error instead of
   surfacing as a generic non-zero exit.

3. **A minimum output size is asserted.**
   Tailwind v4 exits 0 on a stylesheet it does not understand and emits only its
   licence banner, so a successful build must now produce at least
   `TailwindBuilder.minOutputBytes` bytes or the build fails loudly with the
   compiler output attached.

   The floor is **1 KiB**, calibrated against Tailwind v4.3.0: a stylesheet still
   using the v3 `@tailwind` directives exits 0 and yields ~170 B, while a valid
   one with only ~12 classes yields ~8.7 kB (~7.4 kB with `--minify`). 1 KiB sits
   inside that gap. A higher floor (e.g. 20 KiB) would reject legitimate output
   from a young site and block every build.

4. **`canRead` widened to `content/**`.**
   Since v4 scans the project automatically, the build graph must invalidate the
   stylesheet when Markdown or YAML content changes — otherwise edits under
   `content/` produce stale CSS.

### Removed dependencies

- `build_modules` — the scratch space is no longer used; the builder now writes
  a single self-contained stylesheet into a private temp directory.
- `build_runner` (dev) — this package generates no Dart of its own.
- With `build_modules` gone, `build_web_compilers` also leaves the dependency
  graph of consuming projects, which is where it causes the most trouble.

### Changed constraints

- `build`: `^4.0.0` → `^4.0.7`. `build` 4.0.8+ requires `analyzer >=13.3.0`,
  while `jaspr_builder` pins `analyzer ^12.1.0`. Those cannot resolve together,
  and `analyzer` is their only point of contact, so `dart pub get` fails
  outright in a consuming Jaspr project. Raising the floor to 4.0.7 lets the
  resolver back off to the newest `build` that coexists with
  `jaspr_builder`'s analyzer constraint. Nothing here needs build APIs newer
  than 4.0.7.