import 'dart:convert';

/// The 10 documents collected during Rider KYC onboarding. Each has a stable storage filename
/// *base* (RiderKycUploadService suffixes it with `_g{pickGeneration}` per upload attempt, so two
/// generations of the same slot never collide on one object) and a fixed field name expected
/// by the `create-rider-kyc` edge function body.
enum KycDocSlot {
  riderSelfie,
  aadhaarFront,
  aadhaarBack,
  panFront,
  panBack,
  licenseFront,
  licenseBack,
  vehicleImage,
  vehicleRcFront,
  vehicleRcBack,
}

extension KycDocSlotMeta on KycDocSlot {
  String get storageFileName {
    switch (this) {
      case KycDocSlot.riderSelfie:
        return 'rider_image';
      case KycDocSlot.aadhaarFront:
        return 'aadhaar_front';
      case KycDocSlot.aadhaarBack:
        return 'aadhaar_back';
      case KycDocSlot.panFront:
        return 'pan_front';
      case KycDocSlot.panBack:
        return 'pan_back';
      case KycDocSlot.licenseFront:
        return 'license_front';
      case KycDocSlot.licenseBack:
        return 'license_back';
      case KycDocSlot.vehicleImage:
        return 'vehicle_image';
      case KycDocSlot.vehicleRcFront:
        return 'vehicle_rc_front';
      case KycDocSlot.vehicleRcBack:
        return 'vehicle_rc_back';
    }
  }

  /// Field name `create-rider-kyc` expects this document's storage path under.
  String get createRiderKycField {
    switch (this) {
      case KycDocSlot.riderSelfie:
        return 'rider_image';
      case KycDocSlot.aadhaarFront:
        return 'aadhaar_front_image';
      case KycDocSlot.aadhaarBack:
        return 'aadhaar_back_image';
      case KycDocSlot.panFront:
        return 'pan_front_image';
      case KycDocSlot.panBack:
        return 'pan_back_image';
      case KycDocSlot.licenseFront:
        return 'license_front_image';
      case KycDocSlot.licenseBack:
        return 'license_back_image';
      case KycDocSlot.vehicleImage:
        return 'vehicle_image';
      case KycDocSlot.vehicleRcFront:
        return 'vehicle_rc_front_image';
      case KycDocSlot.vehicleRcBack:
        return 'vehicle_rc_back_image';
    }
  }
}

enum KycUploadStatus { idle, picked, uploading, uploaded, failed }

KycUploadStatus _statusFromName(String? name) {
  return KycUploadStatus.values.firstWhere(
    (s) => s.name == name,
    orElse: () => KycUploadStatus.idle,
  );
}

/// Per-document upload state. `pickGeneration` is bumped on every fresh pick of this slot so an
/// upload that was already in flight for a superseded pick can detect it's stale when it
/// eventually completes and discard its own result instead of clobbering the newer one.
class KycDocUploadState {
  final KycUploadStatus status;
  final String? localPath;
  final String? remotePath;
  final int attempts;
  final String? lastError;
  final int pickGeneration;

  const KycDocUploadState({
    this.status = KycUploadStatus.idle,
    this.localPath,
    this.remotePath,
    this.attempts = 0,
    this.lastError,
    this.pickGeneration = 0,
  });

  KycDocUploadState copyWith({
    KycUploadStatus? status,
    String? localPath,
    String? remotePath,
    int? attempts,
    String? lastError,
    bool clearLastError = false,
    int? pickGeneration,
  }) {
    return KycDocUploadState(
      status: status ?? this.status,
      localPath: localPath ?? this.localPath,
      remotePath: remotePath ?? this.remotePath,
      attempts: attempts ?? this.attempts,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      pickGeneration: pickGeneration ?? this.pickGeneration,
    );
  }

  Map<String, dynamic> toJson() => {
        'status': status.name,
        'localPath': localPath,
        'remotePath': remotePath,
        'attempts': attempts,
        'lastError': lastError,
        'pickGeneration': pickGeneration,
      };

  factory KycDocUploadState.fromJson(Map<String, dynamic> json) => KycDocUploadState(
        status: _statusFromName(json['status'] as String?),
        localPath: json['localPath'] as String?,
        remotePath: json['remotePath'] as String?,
        attempts: (json['attempts'] as num?)?.toInt() ?? 0,
        lastError: json['lastError'] as String?,
        pickGeneration: (json['pickGeneration'] as num?)?.toInt() ?? 0,
      );
}

/// The full local upload session for one KYC attempt: a stable folder (persisted across app
/// restarts) plus the upload state of every document slot.
class KycUploadSession {
  final String sessionFolder;
  final int attemptNumber;
  final Map<KycDocSlot, KycDocUploadState> docs;

  const KycUploadSession({
    required this.sessionFolder,
    required this.attemptNumber,
    required this.docs,
  });

  factory KycUploadSession.fresh({
    required String sessionFolder,
    required int attemptNumber,
  }) {
    return KycUploadSession(
      sessionFolder: sessionFolder,
      attemptNumber: attemptNumber,
      docs: {for (final slot in KycDocSlot.values) slot: const KycDocUploadState()},
    );
  }

  bool get allUploaded =>
      KycDocSlot.values.every((slot) => docs[slot]?.status == KycUploadStatus.uploaded);

  KycUploadSession copyWithDoc(KycDocSlot slot, KycDocUploadState state) {
    final next = Map<KycDocSlot, KycDocUploadState>.from(docs);
    next[slot] = state;
    return KycUploadSession(sessionFolder: sessionFolder, attemptNumber: attemptNumber, docs: next);
  }

  Map<String, dynamic> toJson() => {
        'sessionFolder': sessionFolder,
        'attemptNumber': attemptNumber,
        'docs': docs.map((slot, state) => MapEntry(slot.name, state.toJson())),
      };

  factory KycUploadSession.fromJson(Map<String, dynamic> json) {
    final rawDocs = (json['docs'] as Map?)?.cast<String, dynamic>() ?? {};
    final docs = <KycDocSlot, KycDocUploadState>{};
    for (final slot in KycDocSlot.values) {
      final raw = rawDocs[slot.name];
      docs[slot] = raw is Map
          ? KycDocUploadState.fromJson(raw.cast<String, dynamic>())
          : const KycDocUploadState();
    }
    return KycUploadSession(
      sessionFolder: json['sessionFolder'] as String,
      attemptNumber: (json['attemptNumber'] as num).toInt(),
      docs: docs,
    );
  }

  String encode() => jsonEncode(toJson());

  static KycUploadSession? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return KycUploadSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}
