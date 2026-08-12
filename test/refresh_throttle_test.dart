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

  test('failures back off through 1, 5, 15 and 30 minutes', () async {
    var now = DateTime.utc(2026, 8, 12, 12);
    final throttle = RefreshThrottle(now: () => now);
    const expected = [
      Duration(minutes: 1),
      Duration(minutes: 5),
      Duration(minutes: 15),
      Duration(minutes: 30),
      Duration(minutes: 30),
    ];

    for (final cooldown in expected) {
      expect(await throttle.recordFailure('codex'), cooldown);
      final decision = await throttle.decisionFor('codex');
      expect(decision.allowed, isFalse);
      expect(decision.remaining, cooldown);
      now = now.add(cooldown + const Duration(seconds: 1));
    }
  });

  test('success and account edits reset the failure backoff', () async {
    var now = DateTime.utc(2026, 8, 12, 12);
    final throttle = RefreshThrottle(now: () => now);

    await throttle.recordFailure('codex');
    now = now.add(const Duration(minutes: 2));
    expect(await throttle.recordFailure('codex'), const Duration(minutes: 5));

    await throttle.recordSuccess('codex');
    now = now.add(const Duration(minutes: 2));
    expect(await throttle.recordFailure('codex'), const Duration(minutes: 1));

    await throttle.clear('codex');
    expect((await throttle.decisionFor('codex')).allowed, isTrue);
  });
}
