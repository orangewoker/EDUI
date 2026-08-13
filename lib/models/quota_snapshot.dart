class QuotaWindow {
  const QuotaWindow({
    required this.label,
    required this.remainingPercent,
    this.resetAt,
  });

  final String label;
  final double remainingPercent;
  final DateTime? resetAt;

  Map<String, dynamic> toJson() => {
    'label': label,
    'remainingPercent': remainingPercent,
    'resetAt': resetAt?.toIso8601String(),
  };

  factory QuotaWindow.fromJson(Map<String, dynamic> json) => QuotaWindow(
    label: '${json['label'] ?? '额度'}',
    remainingPercent: (json['remainingPercent'] as num).toDouble(),
    resetAt: json['resetAt'] == null
        ? null
        : DateTime.tryParse('${json['resetAt']}'),
  );
}

class QuotaSnapshot {
  const QuotaSnapshot({
    required this.accountId,
    required this.accountName,
    required this.remaining,
    required this.unit,
    required this.updatedAt,
    this.limit,
    this.used,
    this.resetAt,
    this.requestLimit,
    this.requestRemaining,
    this.message,
    this.planLabel,
    this.quotaWindows = const [],
    this.unlimited = false,
  });

  final String accountId;
  final String accountName;
  final double remaining;
  final double? limit;
  final double? used;
  final String unit;
  final DateTime updatedAt;
  final DateTime? resetAt;
  final int? requestLimit;
  final int? requestRemaining;
  final String? message;
  final String? planLabel;
  final List<QuotaWindow> quotaWindows;
  final bool unlimited;

  double? get remainingRatio {
    if (limit == null || limit! <= 0) return null;
    return (remaining / limit!).clamp(0, 1);
  }

  Map<String, dynamic> toJson() => {
    'accountId': accountId,
    'accountName': accountName,
    'remaining': remaining,
    'limit': limit,
    'used': used,
    'unit': unit,
    'updatedAt': updatedAt.toIso8601String(),
    'resetAt': resetAt?.toIso8601String(),
    'requestLimit': requestLimit,
    'requestRemaining': requestRemaining,
    'message': message,
    'planLabel': planLabel,
    'quotaWindows': quotaWindows.map((item) => item.toJson()).toList(),
    'unlimited': unlimited,
  };

  factory QuotaSnapshot.fromJson(Map<String, dynamic> json) => QuotaSnapshot(
    accountId: '${json['accountId']}',
    accountName: '${json['accountName']}',
    remaining: (json['remaining'] as num).toDouble(),
    limit: (json['limit'] as num?)?.toDouble(),
    used: (json['used'] as num?)?.toDouble(),
    unit: '${json['unit']}',
    updatedAt: DateTime.parse('${json['updatedAt']}'),
    resetAt: json['resetAt'] == null
        ? null
        : DateTime.parse('${json['resetAt']}'),
    requestLimit: (json['requestLimit'] as num?)?.round(),
    requestRemaining: (json['requestRemaining'] as num?)?.round(),
    message: json['message'] as String?,
    planLabel: json['planLabel'] as String?,
    quotaWindows: json['quotaWindows'] is List
        ? (json['quotaWindows'] as List)
              .whereType<Map>()
              .map(
                (item) => QuotaWindow.fromJson(Map<String, dynamic>.from(item)),
              )
              .toList()
        : const [],
    unlimited: json['unlimited'] == true,
  );
}
