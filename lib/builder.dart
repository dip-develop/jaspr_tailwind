import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

/// Builds `web/*.tw.css` into `web/*.css` with the Tailwind CSS v4 CLI.
///
/// Forked from `shubhamlav/jaspr_tailwind` @ 4d03ae1 (v0.3.6), which targets
/// Tailwind v3. Differences, all forced by v4 removing `@tailwind`, `--content`
/// and `--config`:
///
/// * source globs are injected as absolute `@source` directives appended to
///   the stylesheet, instead of passed as `--content` (v4 resolves `@source`
///   relative to the stylesheet, and the compiled copy lives in a temp dir);
/// * the `Process.run` result is checked -- upstream discards it, which makes
///   every Tailwind failure silent;
/// * the output size is asserted, because v4 exits 0 on a stylesheet it does
///   not understand;
/// * `canRead` covers `content/**` as well, because v4 scans the project
///   automatically and would otherwise emit stale CSS after a Markdown edit.
///
/// Caveat: the CLI is invoked with `runInShell: true`, so the argument vector is
/// joined and re-parsed by the shell. Any path that reaches `args` -- the temp
/// dir, or the package root the `@source` globs are built from -- must therefore
/// be free of spaces. Keep the checkout path space-free; the shell would
/// otherwise split a path and fail in a confusing way.
Builder buildStylesheet(BuilderOptions options) => TailwindBuilder(options);

class TailwindBuilder implements Builder {
  TailwindBuilder(this.options);

  final BuilderOptions options;

  /// Package-relative directories scanned for class names.
  static const _sourceDirs = ['lib', 'web'];

  /// Package-relative directories excluded from scanning. The vendored builder
  /// is itself Dart source inside the project tree and would otherwise be
  /// scanned for class names.
  static const _excludedDirs = ['packages'];

  /// Smallest stylesheet this builder will accept, in bytes.
  ///
  /// Calibrated against Tailwind v4.3.0, measured on this repo's setup:
  ///
  /// | input                                             | exit | size    |
  /// |---------------------------------------------------|------|---------|
  /// | v3 `@tailwind` directives (the failure we catch)  | 0    | ~170 B  |
  /// | valid stylesheet, ~12 classes, unminified          | 0    | ~8.7 kB |
  /// | valid stylesheet, ~12 classes, `--minify`         | 0    | ~7.4 kB |
  ///
  /// The failure mode v4 exhibits is not a non-zero exit: it exits 0 and emits
  /// only its licence banner plus a few stray legacy utilities. So the check
  /// discriminates on *size*, and the useful signal is the ~40x gap between
  /// ~170 B and ~7.4 kB.
  ///
  /// 1 KiB sits inside that gap with margin on both sides. Do **not** raise this
  /// toward "a real stylesheet is big" (e.g. 20 KiB): a young site with few
  /// classes minifies to well under that, and the check would then reject
  /// perfectly good output and block every build. Raise it only alongside the
  /// failure signature above.
  static const minOutputBytes = 1024;

  /// Extra CLI flags from `build.yaml`'s `defaults.release_options.tailwindcss`.
  ///
  /// `BuilderOptions.config` is `Map<String, dynamic>`, so this value may
  /// arrive as a bare scalar or as a list depending on the YAML form. Accept
  /// both rather than assuming one.
  List<String> get _extraArgs {
    final configured = options.config['tailwindcss'];
    return switch (configured) {
      null => const <String>[],
      final Iterable<Object?> it => it.map((e) => '$e').toList(),
      final Object? other => ['$other'],
    };
  }

  @override
  Future<void> build(BuildStep buildStep) async {
    // Re-run whenever a Dart file or a content file changes. Without this the
    // stylesheet is built once and never refreshed.
    final dartAssets =
        await buildStep.findAssets(Glob('{lib,web}/**/*.dart')).toList();
    final contentAssets =
        await buildStep.findAssets(Glob('content/**/*.{md,yaml}')).toList();
    await Future.wait(
      [...dartAssets, ...contentAssets].map(buildStep.canRead),
    );

    final outputId =
        buildStep.inputId.changeExtension('').changeExtension('.css');

    // Tailwind v4 resolves `@source` relative to the stylesheet, and the
    // stylesheet the CLI reads is a temp file. Absolute paths from the package
    // root are the only thing that resolves reliably. (The builder already
    // assumes `Directory.current` is the package root -- upstream used it for
    // `--config` and `--content`.)
    final packageRoot = Directory.current.path;

    // Must be appended, not prepended: v4 requires `@import` to come before
    // any other rule, so a directive above `@import "tailwindcss"` would void
    // the import.
    final prepared =
        StringBuffer(await buildStep.readAsString(buildStep.inputId));
    if (!prepared.toString().endsWith('\n')) prepared.writeln();
    for (final dir in _sourceDirs) {
      prepared.writeln(
          '@source "${_cssString(p.join(packageRoot, dir, '**', '*.dart'))}";');
    }
    for (final dir in _excludedDirs) {
      prepared
          .writeln('@source not "${_cssString(p.join(packageRoot, dir))}";');
    }

    final workDir = await Directory.systemTemp.createTemp('jaspr_tailwind.');
    try {
      final inputFile = File(p.join(workDir.path, 'input.css'))
        ..writeAsStringSync(prepared.toString());
      final outputFile = File(p.join(workDir.path, 'output.css'));

      final args = <String>[
        '--input',
        inputFile.path,
        '--output',
        outputFile.path,
        ..._extraArgs,
      ];

      // See the class docs: with runInShell the arguments are joined unquoted,
      // so no path passed here may contain a space.
      final ProcessResult result;
      try {
        result = await Process.run(
          'tailwindcss',
          args,
          runInShell: true,
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
      } on ProcessException catch (e) {
        throw StateError(
          'jaspr_tailwind: could not run the `tailwindcss` CLI. Install the '
          'standalone Tailwind CSS v4 binary on PATH; `tailwindcss --help` '
          'must list --minify and must not list --content.\n'
          'Underlying error: ${e.message}',
        );
      }

      // On success Tailwind writes its banner ("Done in 11ms") to stderr.
      final stderrText = '${result.stderr}'.trim();
      if (stderrText.isNotEmpty) {
        log.info('jaspr_tailwind: $stderrText');
      }

      // runInShell on POSIX exits with the child's status: its own code, 127 if
      // the binary is not on PATH, 126 if it is not executable. One check covers
      // all three.
      if (result.exitCode != 0) {
        throw StateError(
          'jaspr_tailwind: `tailwindcss` failed for ${buildStep.inputId} '
          '(exit ${result.exitCode}).\n'
          'Command: tailwindcss ${args.join(' ')}\n'
          'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
        );
      }

      if (!outputFile.existsSync()) {
        throw StateError(
          'jaspr_tailwind: `tailwindcss` exited 0 but wrote no output for '
          '${buildStep.inputId}.',
        );
      }

      // Exit 0 is not evidence of output: v4 exits 0 on a stylesheet it does
      // not understand and emits only its licence banner.
      final byteLength = await outputFile.length();
      if (byteLength < minOutputBytes) {
        throw StateError(
          'jaspr_tailwind: `tailwindcss` exited 0 but produced only '
          '$byteLength bytes for ${buildStep.inputId} (floor: '
          '$minOutputBytes). No utilities were generated -- almost always a '
          'wrong `@source` path, or a stylesheet still using the v3 '
          '`@tailwind` directives.\n'
          'Output:\n${outputFile.readAsStringSync()}',
        );
      }

      await buildStep.writeAsString(outputId, outputFile.readAsStringSync());
    } finally {
      if (workDir.existsSync()) {
        workDir.deleteSync(recursive: true);
      }
    }
  }

  @override
  Map<String, List<String>> get buildExtensions => {
        'web/{{file}}.tw.css': ['web/{{file}}.css'],
      };
}

/// Renders [path] as a CSS string literal: posix separators, with `"` and `\`
/// escaped. `@source` values are CSS strings, so the quoting matters.
String _cssString(String path) => p.posix
    .joinAll(p.split(path))
    .replaceAll(r'\', r'\\')
    .replaceAll('"', r'\"');
