import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:waydrop_diagnostic_host/main.dart' as host;

void main() {
  const directory = '.';
  String source(String relative) =>
      File('$directory/$relative').readAsStringSync().replaceAll('\r\n', '\n');

  test(
    'resolved versions remain pinned and Android plugins stay offline-only',
    () {
      Map<String, String> versions(String lock) => {
        for (final match in RegExp(
          r'^  ([a-z_]+):\n.*?^    version: "([^"]+)"',
          multiLine: true,
          dotAll: true,
        ).allMatches(lock))
          match[1]!: match[2]!,
      };
      final parent = versions(source('../../pubspec.lock'));
      final resolved = versions(source('pubspec.lock'));
      for (final package in resolved.entries) {
        expect(parent[package.key], package.value, reason: package.key);
      }
      final plugins =
          jsonDecode(source('.flutter-plugins-dependencies')) as Map;
      final android = ((plugins['plugins'] as Map)['android'] as List)
          .map((plugin) => (plugin as Map)['name'])
          .toSet();
      expect(android, {'jni', 'jni_flutter', 'path_provider_android'});
    },
  );

  test(
    'standalone dependencies exclude the full app and all backend plugins',
    () {
      final pubspec = source('pubspec.yaml');
      final dependencies = RegExp(
        r'^dependencies:\n(.*?)^dev_dependencies:',
        multiLine: true,
        dotAll: true,
      ).firstMatch(pubspec)![1]!;
      final names = RegExp(
        r'^  ([a-z_]+):',
        multiLine: true,
      ).allMatches(dependencies).map((m) => m[1]).toSet();
      expect(names, {'flutter', 'crypto', 'path', 'path_provider'});
      expect(pubspec, isNot(contains('path: ../')));
      final candidateLock = source('pubspec.lock');
      for (final forbidden in [
        'firebase',
        'supabase',
        'cashfree',
        'geolocator',
        'google_maps',
      ]) {
        expect(candidateLock, isNot(contains(forbidden)));
      }
    },
  );

  test('actual shared source closure imports only offline dependencies', () {
    final visited = <String>{};
    final packages = <String>{};
    void visit(String filePath) {
      final normalized = path.normalize(
        File(filePath).resolveSymbolicLinksSync(),
      );
      if (!visited.add(normalized)) return;
      final contents = File(normalized).readAsStringSync();
      for (final match in RegExp(
        r"(?:import|export)\s+'([^']+)'",
      ).allMatches(contents)) {
        final target = match[1]!;
        if (target.startsWith('package:')) {
          packages.add(target.substring(8).split('/').first);
        } else if (!target.startsWith('dart:')) {
          visit(path.join(path.dirname(normalized), target));
        }
      }
    }

    visit('$directory/lib/main.dart');
    expect(
      visited.length,
      4,
    ); // Host, exact recorder, exact writer, exact tile.
    expect(packages, {'flutter', 'crypto', 'path', 'path_provider'});
    expect(
      visited,
      contains(
        path.normalize(
          path.absolute(
            '../../lib/core/services/diagnostics/ride_diagnostic_export.dart',
          ),
        ),
      ),
    );
  });

  test(
    'Android identity, release isolation and permission-free source are explicit',
    () {
      final gradle = source('android/app/build.gradle.kts');
      expect(
        RegExp(r'applicationId\s*=\s*"([^"]+)"').firstMatch(gradle)![1],
        'com.waydrop.diagnosticvalidation',
      );
      expect(gradle, contains('isDebuggable = false'));
      expect(gradle, isNot(contains('.env')));
      expect(gradle, isNot(contains('key.properties')));
      final settings = source('android/settings.gradle.kts');
      expect(settings, isNot(contains('com.google.gms')));
      expect(settings, isNot(contains('com.google.firebase')));
      final manifest = source('android/app/src/main/AndroidManifest.xml');
      expect(RegExp(r'<uses-permission\b').hasMatch(manifest), isFalse);
      expect(manifest, contains('android:allowBackup="false"'));
      final activity = source(
        'android/app/src/main/kotlin/com/waydrop/diagnosticvalidation/MainActivity.kt',
      );
      expect(activity, contains('class MainActivity : FlutterActivity()'));
      expect(activity, isNot(contains('configureFlutterEngine')));
      expect(source('android/gradlew.bat'), contains('-p "%~dp0."'));
    },
  );

  testWidgets(
    'default host stays disabled with no synthetic event or export action',
    (tester) async {
      expect(host.RideDiagnostics.instance.enabled, isFalse);
      final before = host.RideDiagnostics.instance.exportJson();
      await tester.pumpWidget(const host.SyntheticDiagnosticHost());
      expect(find.text('Diagnostics disabled'), findsOneWidget);
      expect(find.text('Save diagnostic capture'), findsNothing);
      expect(host.RideDiagnostics.instance.exportJson(), before);
    },
    skip: host.RideDiagnostics.instance.enabled,
  );

  testWidgets(
    'enabled host emits one synthetic event and uses exact shared export path',
    (tester) async {
      final recorder = host.RideDiagnostics.instance;
      final before =
          (jsonDecode(recorder.exportJson())['events'] as List).length;
      await tester.pumpWidget(const host.SyntheticDiagnosticHost());
      expect(find.text('Save diagnostic capture'), findsOneWidget);
      expect(find.text('Diagnostics disabled'), findsNothing);
      var data = jsonDecode(recorder.exportJson()) as Map;
      expect((data['events'] as List).length, before + 1);
      final event = (data['events'] as List).last as Map;
      expect(event['event'], 'action');
      expect(event['status'], 'searching');
      expect(
        event.containsKey('endpoint'),
        isFalse,
      ); // No API operation happened.
      expect(event['ride'], recorder.pseudonym('synthetic-export-validation'));
      await tester.pumpWidget(const host.SyntheticDiagnosticHost());
      data = jsonDecode(recorder.exportJson()) as Map;
      expect((data['events'] as List).length, before + 1);
      final expected = recorder.exportJson();
      await tester.runAsync(() async {
        final temporary = await Directory.systemTemp.createTemp(
          'waydrop-host-test-',
        );
        try {
          final exporter = host.RideDiagnosticExport.forTesting(
            recorder: recorder,
            directory: () async => temporary,
          );
          expect(await exporter.save(), host.RideDiagnosticExportResult.saved);
          final capture = File(
            path.join(temporary.path, 'ride-diagnostics', 'capture.json'),
          );
          final contents = await capture.readAsString();
          expect(contents, expected);
          expect(contents, isNot(contains('synthetic-export-validation')));
          expect((jsonDecode(contents) as Map)['schema'], 1);
          expect(await File('${capture.path}.tmp').exists(), isFalse);
        } finally {
          // Only this test's unique, disposable directory.
          await temporary.delete(recursive: true);
        }
      });
    },
    skip: !host.RideDiagnostics.instance.enabled,
  );
}
