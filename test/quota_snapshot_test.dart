import 'package:edui/models/quota_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('quota windows round trip and old snapshots remain compatible', () {
    final now = DateTime.utc(2026, 8, 12, 2);
    final snapshot = QuotaSnapshot(
      accountId: 'codex',
      accountName: 'Codex',
      remaining: 64,
      limit: 100,
      used: 36,
      unit: '%',
      updatedAt: now,
      planLabel: 'K12',
      quotaWindows: [
        QuotaWindow(
          label: '5 小时额度',
          remainingPercent: 64,
          resetAt: now.add(const Duration(hours: 3)),
        ),
        QuotaWindow(
          label: '本周额度',
          remainingPercent: 58,
          resetAt: now.add(const Duration(days: 4)),
        ),
      ],
    );

    final restored = QuotaSnapshot.fromJson(snapshot.toJson());
    expect(restored.quotaWindows, hasLength(2));
    expect(restored.quotaWindows.last.label, '本周额度');
    expect(restored.quotaWindows.last.remainingPercent, 58);
    expect(restored.planLabel, 'K12');

    final legacy = QuotaSnapshot.fromJson({
      'accountId': 'deepseek',
      'accountName': 'DeepSeek',
      'remaining': 12.8,
      'unit': 'CNY',
      'updatedAt': now.toIso8601String(),
    });
    expect(legacy.quotaWindows, isEmpty);
  });
}
