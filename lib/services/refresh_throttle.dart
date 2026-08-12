import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class RefreshThrottle {
  RefreshThrottle({
    Future<SharedPreferences>? preferences,
    DateTime Function()? now,
    this.successCooldown = const Duration(minutes: 1),
    this.failureCooldowns = const [
      Duration(minutes: 1),
      Duration(minutes: 5),
      Duration(minutes: 15),
      Duration(minutes: 30),
    ],
  }) : _preferences = preferences ?? SharedPreferences.getInstance(),
       _now = now ?? DateTime.now;

  static const _storageKey = 'refresh_throttle_v1';

  final Future<SharedPreferences> _preferences;
  final DateTime Function() _now;
  final Duration successCooldown;
  final List<Duration> failureCooldowns;

  Future<RefreshDecision> decisionFor(String accountId) async {
    final state = await _load();
    final entry = state[accountId];
    if (entry == null) return const RefreshDecision.allowed();

    final remaining = entry.nextAllowedAt.difference(_now());
    if (remaining <= Duration.zero) return const RefreshDecision.allowed();
    return RefreshDecision.blocked(
      remaining: remaining,
      consecutiveFailures: entry.consecutiveFailures,
    );
  }

  Future<Duration> recordSuccess(String accountId) async {
    final state = await _load();
    state[accountId] = _RefreshState(
      consecutiveFailures: 0,
      nextAllowedAt: _now().add(successCooldown),
    );
    await _save(state);
    return successCooldown;
  }

  Future<Duration> recordFailure(String accountId) async {
    final state = await _load();
    final failureCount = (state[accountId]?.consecutiveFailures ?? 0) + 1;
    final cooldown =
        failureCooldowns[(failureCount - 1).clamp(
          0,
          failureCooldowns.length - 1,
        )];
    state[accountId] = _RefreshState(
      consecutiveFailures: failureCount,
      nextAllowedAt: _now().add(cooldown),
    );
    await _save(state);
    return cooldown;
  }

  Future<void> clear(String accountId) async {
    final state = await _load();
    if (state.remove(accountId) != null) await _save(state);
  }

  Future<Map<String, _RefreshState>> _load() async {
    final prefs = await _preferences;
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.value is Map)
            '${entry.key}': _RefreshState.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            ),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _save(Map<String, _RefreshState> state) async {
    final prefs = await _preferences;
    await prefs.setString(
      _storageKey,
      jsonEncode({
        for (final entry in state.entries) entry.key: entry.value.toJson(),
      }),
    );
  }
}

class RefreshDecision {
  const RefreshDecision.allowed()
    : allowed = true,
      remaining = Duration.zero,
      consecutiveFailures = 0;

  const RefreshDecision.blocked({
    required this.remaining,
    required this.consecutiveFailures,
  }) : allowed = false;

  final bool allowed;
  final Duration remaining;
  final int consecutiveFailures;
}

class _RefreshState {
  const _RefreshState({
    required this.consecutiveFailures,
    required this.nextAllowedAt,
  });

  factory _RefreshState.fromJson(Map<String, dynamic> json) => _RefreshState(
    consecutiveFailures: int.tryParse('${json['consecutiveFailures']}') ?? 0,
    nextAllowedAt:
        DateTime.tryParse('${json['nextAllowedAt']}') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );

  final int consecutiveFailures;
  final DateTime nextAllowedAt;

  Map<String, dynamic> toJson() => {
    'consecutiveFailures': consecutiveFailures,
    'nextAllowedAt': nextAllowedAt.toIso8601String(),
  };
}
