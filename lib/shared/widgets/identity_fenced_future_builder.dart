import 'package:flutter/material.dart';
import 'package:waydrop/core/services/session/identity_operation_scope.dart';

/// Display-only fence for a captured account's asynchronous result. Retired
/// evidence is hidden, never interpreted as an empty row or a zero amount.
class IdentityFencedFutureBuilder<T> extends StatefulWidget {
  const IdentityFencedFutureBuilder({super.key, required this.ownerUserId,
    required this.future, required this.builder});
  final String? ownerUserId;
  final Future<T>? future;
  final AsyncWidgetBuilder<T> builder;
  @override
  State<IdentityFencedFutureBuilder<T>> createState() => _IdentityFencedFutureBuilderState<T>();
}

class _IdentityFencedFutureBuilderState<T> extends State<IdentityFencedFutureBuilder<T>> {
  late final IdentityOperationScope _scope;
  late final IdentityOperation _operation;
  @override
  void initState() {
    super.initState();
    _scope = IdentityOperationScope.forWidget(() => mounted,
        onIdentityChanged: () => setState(() {}));
    _operation = _scope.begin();
  }
  @override
  void dispose() { _scope.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    if (!_operation.isCurrent || _operation.userId != widget.ownerUserId) return const SizedBox.shrink();
    return FutureBuilder<T>(future: widget.future, builder: (context, snapshot) {
      if (!_operation.isCurrent || _operation.userId != widget.ownerUserId) return const SizedBox.shrink();
      return widget.builder(context, snapshot);
    });
  }
}
