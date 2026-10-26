import 'package:flutter/material.dart';

// Reuse the real sources, not the full app package/dependency graph.
import 'shared_sources/core/services/diagnostics/ride_diagnostics.dart';
import 'shared_sources/shared/widgets/ride_diagnostic_export_tile.dart';

// Tests access these same source URIs/singletons rather than importing a second copy.
export 'shared_sources/core/services/diagnostics/ride_diagnostics.dart';
export 'shared_sources/core/services/diagnostics/ride_diagnostic_export.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SyntheticDiagnosticHost());
}

class SyntheticDiagnosticHost extends StatefulWidget {
  const SyntheticDiagnosticHost({super.key});

  @override
  State<SyntheticDiagnosticHost> createState() =>
      _SyntheticDiagnosticHostState();
}

class _SyntheticDiagnosticHostState extends State<SyntheticDiagnosticHost> {
  @override
  void initState() {
    super.initState();
    // One fixed local event per host mount; no API attempt or real account/ride.
    RideDiagnostics.instance.begin(
      isCurrent: () => mounted,
      rawRide: 'synthetic-export-validation',
      status: RideStatus.searching,
      surface: RideSurface.booking,
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('Synthetic export validation')),
      body: ListView(
        children: [
          const ListTile(
            title: Text('Local synthetic data only'),
            subtitle: Text('No accounts, rides or backend connections'),
          ),
          if (!RideDiagnostics.instance.enabled)
            const ListTile(title: Text('Diagnostics disabled')),
          const RideDiagnosticExportTile(),
        ],
      ),
    ),
  );
}
