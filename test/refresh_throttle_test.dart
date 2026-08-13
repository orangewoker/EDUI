import 'package:edui/services/refresh_throttle.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('successful refresh starts a persistent 60 second cooldown', () async {
    var now = DateTime.utc(2026, 8, 12, 12);
    final throttle = RefreshThrottle(now: () => now);

    expect((await throttle.decisionFor('codex')).allowed, isTrue);
    await throttle.recordSuccess('codex');

    final immediate = await throttle.decisionFor('codex');
    expect(immediate.allowed, isFalse);
    expect(immediate.remaining, const Duration(minutes: 1));

    now = now.add(const Duration(seconds: 61));
    expect((await throttle.decisionFor('codex')).allowed, isTrue);
  });

  test('rate limit honors the server cooldown without escalation', () async {
    var now = DateTime.utc(2026, 8, 12, 12);
    final throttle = RefreshThrottle(now: () => now);
    const cooldown = Duration(minutes: 2);

    expect(
      await throttle.recordRateLimit('codex', cooldown: cooldown),
      cooldown,
    );
    final decision = await throttle.decisionFor('codex');
    expect(decision.allowed, isFalse);
    expect(decision.remaining, cooldown);
    expect(decision.reason, RefreshBlockReason.rateLimit);

    now = now.add(const Duration(minutes: 2, seconds: 1));
    expect((await throttle.decisionFor('codex')).allowed, isTrue);
  });

  test('clear removes success and rate-limit cooldowns', () async {
    var now = DateTime.utc(2026, 8, 12, 12);
    final throttle = RefreshThrottle(now: () => now);

    await throttle.recordRateLimit('codex');
    await throttle.clear('codex');
    expect((await throttle.decisionFor('codex')).allowed, isTrue);
  });

  test('legacy failure backoff is ignored after upgrade', () async {
    SharedPreferences.setMockInitialValues({
      'refresh_throttle_v1':
          '{"codex":{"consecutiveFailures":4,"nextAllowedAt":"2099-01-01T00:00:00.000Z"}}',
    });
    final throttle = RefreshThrottle();
    expect((await throttle.decisionFor('codex')).allowed, isTrue);
  });
}
