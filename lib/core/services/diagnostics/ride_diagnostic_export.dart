import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'ride_diagnostics.dart';

enum RideDiagnosticExportResult {
  saved,
  disabled,
  empty,
  tooLarge,
  busy,
  unavailable,
  failed,
}

/// Explicit local export only. Never reads application logs or arbitrary files.
class RideDiagnosticExport {
  RideDiagnosticExport._(
    this._recorder,
    this._directory, {
    Future<void> Function(File, List<int>)? writeTemporary,
    Future<void> Function(File, File)? replace,
  }) : _writeTemporary = writeTemporary ?? _write,
       _replace = replace ?? _rename;

  static final instance = RideDiagnosticExport._(
    RideDiagnostics.instance,
    () async => Platform.isAndroid ? await getExternalStorageDirectory() : null,
  );

  /// Immutable local test dependencies; cannot enable the production singleton.
  @visibleForTesting
  factory RideDiagnosticExport.forTesting({
    required RideDiagnostics recorder,
    required Future<Directory?> Function() directory,
    Future<void> Function(File, List<int>)? writeTemporary,
    Future<void> Function(File, File)? replace,
  }) {
    if (!kDebugMode) {
      throw StateError('Diagnostic export test seam unavailable');
    }
    return RideDiagnosticExport._(
      recorder,
      directory,
      writeTemporary: writeTemporary,
      replace: replace,
    );
  }

  static const maxBytes = 4 * 1024 * 1024;
  static const directoryName = 'ride-diagnostics';
  static const fileName = 'capture.json';
  static const temporaryName = 'capture.json.tmp';
  // Shared across both settings actions and all exporter instances.
  static bool _busy = false;
  final RideDiagnostics _recorder;
  final Future<Directory?> Function() _directory;
  final Future<void> Function(File, List<int>) _writeTemporary;
  final Future<void> Function(File, File) _replace;

  bool get enabled => _recorder.enabled;

  static Future<void> _write(File file, List<int> bytes) async {
    await file.writeAsBytes(bytes, flush: true);
  }

  static Future<void> _rename(File temporary, File destination) async {
    // Same directory/filesystem; never delete the last valid capture first.
    await temporary.rename(destination.path);
  }

  static Future<bool> _ordinaryFileOrAbsent(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    return type == FileSystemEntityType.notFound ||
        type == FileSystemEntityType.file;
  }

  Future<RideDiagnosticExportResult> save() async {
    if (!enabled) return RideDiagnosticExportResult.disabled;
    if (_busy) return RideDiagnosticExportResult.busy;
    _busy = true;
    File? ownedTemporary;
    var result = RideDiagnosticExportResult.failed;
    try {
      // This is the only source of export bytes. Do not substitute logs/payloads.
      final json = _recorder.exportJson();
      final bytes = utf8.encode(json);
      if (bytes.length > maxBytes) {
        result = RideDiagnosticExportResult.tooLarge;
      } else if ((jsonDecode(json) as Map)['events'] is! List ||
          ((jsonDecode(json) as Map)['events'] as List).isEmpty) {
        result = RideDiagnosticExportResult.empty;
      } else {
        final base = await _directory();
        if (base == null) {
          result = RideDiagnosticExportResult.unavailable;
        } else {
          final directory = Directory(path.join(base.path, directoryName));
          final type = await FileSystemEntity.type(
            directory.path,
            followLinks: false,
          );
          if (type != FileSystemEntityType.notFound &&
              type != FileSystemEntityType.directory) {
            return RideDiagnosticExportResult.failed;
          }
          await directory.create(); // Only this child; no recursive creation.
          final temporary = File(path.join(directory.path, temporaryName));
          final destination = File(path.join(directory.path, fileName));
          if (!await _ordinaryFileOrAbsent(temporary) ||
              !await _ordinaryFileOrAbsent(destination)) {
            return RideDiagnosticExportResult.failed;
          }
          ownedTemporary = temporary;
          await _writeTemporary(temporary, bytes);
          await _replace(temporary, destination);
          result = RideDiagnosticExportResult.saved;
        }
      }
    } catch (_) {
      // Fixed categories only: never log/display exceptions, bytes or paths.
      result = RideDiagnosticExportResult.failed;
    } finally {
      try {
        // Never recursive; never delete the fixed capture or unrelated files.
        if (ownedTemporary != null &&
            await FileSystemEntity.type(
                  ownedTemporary.path,
                  followLinks: false,
                ) ==
                FileSystemEntityType.file) {
          await ownedTemporary.delete();
        }
      } catch (_) {
        result = RideDiagnosticExportResult.failed;
      } finally {
        _busy = false;
      }
    }
    return result;
  }
}
