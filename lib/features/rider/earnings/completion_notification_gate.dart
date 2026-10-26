enum CompletionTerminalStatus { completed, delivered }
enum CompletionEvidence { confirmed, failed, uncertain }
enum CompletionSource { rpc, realtime }

/// Local evidence carrier, not an authentication or authorization mechanism.
/// The producer must first validate terminal server evidence and initiating identity.
class CompletionContext {
  const CompletionContext({required this.accountId, required this.riderId,
    required this.orderId, required this.status, required this.serverVersion,
    required this.ownerGeneration, required this.evidence, required this.source});
  final String accountId;
  final String riderId;
  final String orderId;
  final CompletionTerminalStatus status;
  final DateTime serverVersion;
  final int ownerGeneration;
  final CompletionEvidence evidence;
  final CompletionSource source;
}

/// Instantiate per navigation owner. Never shared globally or across lifetimes.
class CompletionNotificationGate {
  CompletionNotificationGate(this._accountId, this._riderId);
  String _accountId;
  String _riderId;
  int _generation = 0;
  bool _disposed = false;
  final _versions = <String, DateTime>{};
  int get generation => _generation;
  bool owns(String accountId, String riderId, int generation) => !_disposed &&
      accountId == _accountId && riderId == _riderId && generation == _generation;
  void retireAndBind(String accountId, String riderId) {
    _generation++;
    _accountId = accountId;
    _riderId = riderId;
    _versions.clear();
  }
  void dispose() { _disposed = true; _generation++; _versions.clear(); }
  bool accept(CompletionContext context) {
    if (context.evidence != CompletionEvidence.confirmed ||
        context.accountId.isEmpty || context.riderId.isEmpty || context.orderId.isEmpty ||
        !context.serverVersion.isUtc ||
        !owns(context.accountId, context.riderId, context.ownerGeneration)) {
      return false;
    }
    final previous = _versions[context.orderId];
    if (previous != null && !context.serverVersion.isAfter(previous)) return false;
    // Source/status differences cannot make same-version terminal replay new.
    _versions[context.orderId] = context.serverVersion;
    return true;
  }
}
