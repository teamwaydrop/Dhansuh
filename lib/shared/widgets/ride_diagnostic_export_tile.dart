import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../core/services/diagnostics/ride_diagnostic_export.dart';

/// Explicit operator action; absent from ordinary builds.
class RideDiagnosticExportTile extends StatefulWidget {
  const RideDiagnosticExportTile({super.key})
    : _testEnabled = null,
      _testSave = null;

  @visibleForTesting
  factory RideDiagnosticExportTile.forTesting({
    Key? key,
    required bool enabled,
    required Future<RideDiagnosticExportResult> Function() save,
  }) {
    if (kDebugMode) {
      return RideDiagnosticExportTile._(key: key, enabled: enabled, save: save);
    }
    throw StateError('Diagnostic export test seam unavailable');
  }

  const RideDiagnosticExportTile._({
    super.key,
    required bool enabled,
    required Future<RideDiagnosticExportResult> Function() save,
  }) : _testEnabled = enabled,
       _testSave = save;
  final bool? _testEnabled;
  final Future<RideDiagnosticExportResult> Function()? _testSave;

  @override
  State<RideDiagnosticExportTile> createState() =>
      _RideDiagnosticExportTileState();
}

class _RideDiagnosticExportTileState extends State<RideDiagnosticExportTile> {
  bool _saving = false;
  bool get _enabled =>
      widget._testEnabled ?? RideDiagnosticExport.instance.enabled;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    var result = RideDiagnosticExportResult.failed;
    try {
      result =
          await (widget._testSave?.call() ??
              RideDiagnosticExport.instance.save());
    } catch (_) {
      // Never show exception details, export contents or filesystem paths.
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
    final message = switch (result) {
      RideDiagnosticExportResult.saved => 'Diagnostic capture saved locally.',
      RideDiagnosticExportResult.disabled => 'Diagnostics are disabled.',
      RideDiagnosticExportResult.empty => 'No diagnostic events to export.',
      RideDiagnosticExportResult.tooLarge =>
        'Diagnostic capture exceeds the export limit.',
      RideDiagnosticExportResult.busy =>
        'A diagnostic export is already running.',
      RideDiagnosticExportResult.unavailable =>
        'Local diagnostic storage is unavailable.',
      RideDiagnosticExportResult.failed => 'Diagnostic export failed.',
    };
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (!_enabled) return const SizedBox.shrink();
    return ListTile(
      leading: const Icon(Icons.save_alt),
      title: const Text('Save diagnostic capture'),
      subtitle: const Text('Sanitized JSON on this device only'),
      enabled: !_saving,
      trailing: _saving
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      onTap: _saving ? null : _save,
    );
  }
}
