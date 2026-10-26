import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:waydrop/core/services/diagnostics/ride_diagnostic_export.dart';
import 'package:waydrop/core/services/diagnostics/ride_diagnostics.dart';
import 'package:waydrop/features/rider/settings/rider_settings_screen.dart';
import 'package:waydrop/features/user/settings/user_settings_screen.dart';
import 'package:waydrop/shared/widgets/ride_diagnostic_export_tile.dart';

RideDiagnostics capture() {
  final recorder = RideDiagnostics(enabled: true);
  recorder.begin(
    isCurrent: () => true,
    rawRide: 'PRIVATE-ORDER',
    rawCorrelation: 'PRIVATE-CORRELATION',
    endpoint: RideEndpoint.booking,
  );
  return recorder;
}

// Test-only serialization faults/size fixtures. Production uses its singleton only.
class SerializationFixture extends RideDiagnostics {
  SerializationFixture(this.json) : super(enabled: true);
  final String json;
  @override
  String exportJson() => json;
}

class ThrowingSerialization extends RideDiagnostics {
  ThrowingSerialization() : super(enabled: true);
  @override
  String exportJson() => throw StateError('PRIVATE-ERROR');
}

void main() {
  late Directory base;
  Directory output() =>
      Directory(path.join(base.path, RideDiagnosticExport.directoryName));
  File fixed() => File(path.join(output().path, RideDiagnosticExport.fileName));
  File temporary() =>
      File(path.join(output().path, RideDiagnosticExport.temporaryName));
  RideDiagnosticExport exporter(
    RideDiagnostics recorder, {
    Future<void> Function(File, List<int>)? write,
    Future<void> Function(File, File)? replace,
  }) => RideDiagnosticExport.forTesting(
    recorder: recorder,
    directory: () async => base,
    writeTemporary: write,
    replace: replace,
  );

  setUp(() async {
    base = await Directory.systemTemp.createTemp('waydrop-export-test-');
  });
  tearDown(() async {
    // Only the unique disposable directory created by this test.
    await base.delete(recursive: true);
  });

  test(
    'default or malformed build key disables singleton and performs no I/O',
    () async {
      // Also run this file with explicit enablement plus a malformed synthetic key.
      expect(RideDiagnostics.instance.enabled, isFalse);
      expect(
        await RideDiagnosticExport.instance.save(),
        RideDiagnosticExportResult.disabled,
      );
      var directories = 0;
      final disabled = RideDiagnosticExport.forTesting(
        recorder: RideDiagnostics(),
        directory: () async {
          directories++;
          return base;
        },
      );
      expect(await disabled.save(), RideDiagnosticExportResult.disabled);
      expect(directories, 0);
      expect(await base.list().isEmpty, isTrue);
    },
  );

  test(
    'writes exactly sanitized recorder JSON, with no raw identifiers',
    () async {
      final recorder = capture();
      final expected = recorder.exportJson();
      expect(await exporter(recorder).save(), RideDiagnosticExportResult.saved);
      final actual = await fixed().readAsString();
      expect(actual, expected);
      expect(actual, isNot(contains('PRIVATE')));
      expect(jsonDecode(actual)['events'], isNotEmpty);
      expect(await temporary().exists(), isFalse);
      expect((await output().list().toList()).length, 1);
    },
  );

  test('empty capture and serialization error never create files', () async {
    expect(
      await exporter(RideDiagnostics(enabled: true)).save(),
      RideDiagnosticExportResult.empty,
    );
    expect(
      await exporter(ThrowingSerialization()).save(),
      RideDiagnosticExportResult.failed,
    );
    expect(
      await exporter(SerializationFixture('invalid JSON')).save(),
      RideDiagnosticExportResult.failed,
    );
    expect(await base.list().isEmpty, isTrue);
    expect(await exporter(capture()).save(), RideDiagnosticExportResult.saved);
  });

  test(
    'exact 4 MiB succeeds; UTF-8 oversize fails without truncating or replacing',
    () async {
      final original = capture().exportJson();
      final exact =
          original +
          (' ' *
              (RideDiagnosticExport.maxBytes - utf8.encode(original).length));
      expect(
        await exporter(SerializationFixture(exact)).save(),
        RideDiagnosticExportResult.saved,
      );
      expect(await fixed().length(), RideDiagnosticExport.maxBytes);
      // Multibyte data: the character count stays below the cap but byte count exceeds it.
      final oversized = original.replaceFirst(
        'session_monotonic',
        'é' * (RideDiagnosticExport.maxBytes ~/ 2),
      );
      expect(oversized.length, lessThan(RideDiagnosticExport.maxBytes));
      expect(
        utf8.encode(oversized).length,
        greaterThan(RideDiagnosticExport.maxBytes),
      );
      expect(
        await exporter(SerializationFixture(oversized)).save(),
        RideDiagnosticExportResult.tooLarge,
      );
      expect(await fixed().readAsString(), exact);
      expect(await temporary().exists(), isFalse);
    },
  );

  test(
    'only one export across instances; captured bytes remain stable during await',
    () async {
      final recorder = capture();
      final expected = recorder.exportJson();
      final entered = Completer<void>();
      final release = Completer<void>();
      final first = exporter(
        recorder,
        write: (file, bytes) async {
          if (!entered.isCompleted) entered.complete();
          await release.future;
          await file.writeAsBytes(bytes, flush: true);
        },
      );
      final pending = first.save();
      await entered.future;
      recorder.begin(isCurrent: () => true, rawRide: 'another-order');
      expect(await first.save(), RideDiagnosticExportResult.busy);
      expect(await exporter(capture()).save(), RideDiagnosticExportResult.busy);
      release.complete();
      expect(await pending, RideDiagnosticExportResult.saved);
      expect(await fixed().readAsString(), expected);
      expect(await first.save(), RideDiagnosticExportResult.saved);
      expect(await fixed().readAsString(), recorder.exportJson());
    },
  );

  for (final failure in ['write', 'replace']) {
    test(
      '$failure failure preserves fixed capture and cleans only owned temp',
      () async {
        expect(
          await exporter(capture()).save(),
          RideDiagnosticExportResult.saved,
        );
        final previous = await fixed().readAsString();
        final unrelated = File(path.join(output().path, 'unrelated.txt'));
        await unrelated.writeAsString('keep');
        final broken = exporter(
          capture(),
          write: failure == 'write'
              ? (file, bytes) async {
                  await file.writeAsBytes(bytes.take(20).toList());
                  throw FileSystemException('PRIVATE-PATH-DETAILS');
                }
              : null,
          replace: failure == 'replace'
              ? (file, destination) async {
                  throw FileSystemException('PRIVATE-PATH-DETAILS');
                }
              : null,
        );
        expect(await broken.save(), RideDiagnosticExportResult.failed);
        expect(await fixed().readAsString(), previous);
        expect(await temporary().exists(), isFalse);
        expect(await unrelated.readAsString(), 'keep');
        expect(
          await exporter(capture()).save(),
          RideDiagnosticExportResult.saved,
        );
      },
    );
  }

  test(
    'successful replacement overwrites only fixed file and stale owned temporary',
    () async {
      await output().create();
      await fixed().writeAsString('previous');
      await temporary().writeAsString('interrupted export');
      final unrelated = File(path.join(output().path, 'unrelated.txt'));
      await unrelated.writeAsString('keep');
      final recorder = capture();
      expect(await exporter(recorder).save(), RideDiagnosticExportResult.saved);
      expect(await fixed().readAsString(), recorder.exportJson());
      expect(await unrelated.readAsString(), 'keep');
      expect(await temporary().exists(), isFalse);
    },
  );

  test(
    'unavailable directory and directory failures return bounded categories',
    () async {
      final unavailable = RideDiagnosticExport.forTesting(
        recorder: capture(),
        directory: () async => null,
      );
      expect(await unavailable.save(), RideDiagnosticExportResult.unavailable);
      final broken = RideDiagnosticExport.forTesting(
        recorder: capture(),
        directory: () async {
          throw FileSystemException('PRIVATE-PATH');
        },
      );
      expect(await broken.save(), RideDiagnosticExportResult.failed);
      expect(await base.list().isEmpty, isTrue);
    },
  );

  for (final collision in ['directory', 'temporary', 'fixed']) {
    test('$collision non-file collision fails without deleting it', () async {
      if (collision == 'directory') {
        await File(output().path).writeAsString('keep');
      } else {
        await output().create();
        await Directory(
          collision == 'temporary' ? temporary().path : fixed().path,
        ).create();
      }
      expect(
        await exporter(capture()).save(),
        RideDiagnosticExportResult.failed,
      );
      if (collision == 'directory') {
        expect(await File(output().path).readAsString(), 'keep');
      } else {
        expect(
          await Directory(
            collision == 'temporary' ? temporary().path : fixed().path,
          ).exists(),
          isTrue,
        );
      }
    });
  }

  testWidgets(
    'ordinary passenger and rider settings contain no export action',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: UserSettingsScreen())),
      );
      expect(find.text('Save diagnostic capture'), findsNothing);
      await tester.pumpWidget(const MaterialApp(home: RiderSettingsScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Save diagnostic capture'), findsNothing);
    },
  );

  testWidgets('enabled action saves once and shows only fixed feedback', (
    tester,
  ) async {
    final release = Completer<RideDiagnosticExportResult>();
    var writes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RideDiagnosticExportTile.forTesting(
            enabled: true,
            save: () {
              writes++;
              return release.future;
            },
          ),
        ),
      ),
    );
    expect(find.text('Save diagnostic capture'), findsOneWidget);
    await tester.tap(find.text('Save diagnostic capture'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.text('Save diagnostic capture'));
    expect(writes, 1);
    release.complete(RideDiagnosticExportResult.saved);
    await tester.pumpAndSettle();
    expect(find.text('Diagnostic capture saved locally.'), findsOneWidget);
    expect(find.textContaining('PRIVATE'), findsNothing);
    expect(find.textContaining(base.path), findsNothing);
  });

  for (final passenger in [true, false]) {
    testWidgets(
      '${passenger ? 'passenger' : 'rider'} settings enabled seam exports only recorder JSON',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        await tester.pumpWidget(
          passenger
              ? const ProviderScope(
                  child: MaterialApp(home: UserSettingsScreen()),
                )
              : const MaterialApp(home: RiderSettingsScreen()),
        );
        await tester.pumpAndSettle();
        final listFinder = find.byType(ListView);
        final list = tester.widget<ListView>(listFinder);
        final children =
            (list.childrenDelegate as SliverChildListDelegate).children;
        expect(children.whereType<RideDiagnosticExportTile>(), hasLength(1));
        expect(find.text('Save diagnostic capture'), findsNothing);
        final recorder = capture();
        final expected = recorder.exportJson();
        final writer = exporter(recorder);
        var saves = 0;
        Future<RideDiagnosticExportResult>? pendingSave;
        // Disabled zero-height tiles can be evicted by the lazy ListView. Reuse
        // the actual Settings children and replace only that tile's dependencies;
        // no build defines or production singleton replacement is needed.
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView(
                padding: list.padding,
                children: [
                  for (final child in children)
                    if (child is RideDiagnosticExportTile)
                      RideDiagnosticExportTile.forTesting(
                        enabled: recorder.enabled,
                        save: () {
                          saves++;
                          return pendingSave = writer.save();
                        },
                      )
                    else
                      child,
                ],
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('Save diagnostic capture'), findsOneWidget);
        // Start and await real filesystem work outside the fake clock.
        await tester.runAsync(() async {
          await tester.tap(find.text('Save diagnostic capture'));
          expect(await pendingSave!, RideDiagnosticExportResult.saved);
          expect(await fixed().readAsString(), expected);
          expect(await temporary().exists(), isFalse);
          expect((await output().list().toList()).length, 1);
        });
        await tester.pumpAndSettle();
        expect(saves, 1);
        expect(find.text('Diagnostic capture saved locally.'), findsOneWidget);
        expect(find.textContaining('PRIVATE'), findsNothing);
        expect(find.textContaining(base.path), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final mode in [
    'empty',
    'unavailable',
    'failure',
    'tooLarge',
    'busy',
    'disabled',
    'throws',
  ]) {
    testWidgets('$mode feedback contains no contents or exception details', (
      tester,
    ) async {
      final result = switch (mode) {
        'empty' => RideDiagnosticExportResult.empty,
        'unavailable' => RideDiagnosticExportResult.unavailable,
        'tooLarge' => RideDiagnosticExportResult.tooLarge,
        'busy' => RideDiagnosticExportResult.busy,
        'disabled' => RideDiagnosticExportResult.disabled,
        _ => RideDiagnosticExportResult.failed,
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RideDiagnosticExportTile.forTesting(
              enabled: true,
              save: () async {
                if (mode == 'throws') throw StateError('PRIVATE-ERROR');
                return result;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Save diagnostic capture'));
      await tester.pumpAndSettle();
      final message = switch (mode) {
        'empty' => 'No diagnostic events to export.',
        'unavailable' => 'Local diagnostic storage is unavailable.',
        'tooLarge' => 'Diagnostic capture exceeds the export limit.',
        'busy' => 'A diagnostic export is already running.',
        'disabled' => 'Diagnostics are disabled.',
        _ => 'Diagnostic export failed.',
      };
      expect(find.text(message), findsOneWidget);
      expect(find.textContaining('PRIVATE'), findsNothing);
    });
  }
  testWidgets('disposal suppresses late export feedback', (tester) async {
    final result = Completer<RideDiagnosticExportResult>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RideDiagnosticExportTile.forTesting(
            enabled: true,
            save: () => result.future,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Save diagnostic capture'));
    await tester.pump();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Replacement'))),
    );
    result.complete(RideDiagnosticExportResult.saved);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'enabled diagnostic build exposes both settings actions',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: UserSettingsScreen())),
      );
      expect(find.text('Save diagnostic capture'), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(home: RiderSettingsScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Save diagnostic capture'), findsOneWidget);
    },
    skip: !RideDiagnostics.instance.enabled,
  );
}
