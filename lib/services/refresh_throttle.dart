import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class RefreshThrottle {
  RefreshThrottle({
    Future<SharedPreferences>? preferences,
    DateTime Function()? now,
    this.successCooldown = const Duration(minutes: 1),
  }) : _preferences = preferences ?? SharedPreferences.getInstance(),
       _now = now ?? DateTime.now;

  // V2 intentionally ignores the old V1 failure backoff. Older releases
  // treated offline, proxy and credential errors as account risk and could
  // leave users blocked for 30 minutes even though no rate limit occurred.
  static const _storageKey = 'refresh_throttle_v2';

  final Future<SharedPreferences> _preferences;
  final DateTime Function() _now;
  final Duration successCooldown;

  Future<RefreshDecision> decisionFor(String accountId) async {
    final state = await _load();
    final entry = state[accountId];
    if (entry == null) return const RefreshDecision.allowed();

    final remaining = entry.nextAllowedAt.difference(_now());
    if (remaining <= Duration.zero) return const RefreshDecision.allowed();
    return RefreshDecision.blocked(remaining: remaining, reason: entry.reason);
  }

  Future<Duration> recordSuccess(String accountId) async {
    final state = await _load();
    state[accountId] = _RefreshState(
      nextAllowedAt: _now().add(successCooldown),
      reason: RefreshBlockReason.recentSuccess,
    );
    await _save(state);
    return successCooldown;
  }

  Future<Duration> recordRateLimit(
    String accountId, {
    Duration cooldown = const Duration(minutes: 5),
  }) async {
    final state = await _load();
    final safeCooldown = cooldown <= Duration.zero
        ? const Duration(minutes: 5)
        : cooldown;
    state[accountId] = _RefreshState(
      nextAllowedAt: _now().add(safeCooldown),
      reason: RefreshBlockReason.rateLimit,
    );
    await _save(state);
    return safeCooldown;
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
      reason = null;

  const RefreshDecision.blocked({required this.remaining, required this.reason})
    : allowed = false;

  final bool allowed;
  final Duration remaining;
  final RefreshBlockReason? reason;
}

enum RefreshBlockReason { recentSuccess, rateLimit }

class _RefreshState {
  const _RefreshState({required this.nextAllowedAt, required this.reason});

  factory _RefreshState.fromJson(Map<String, dynamic> json) => _RefreshState(
    nextAllowedAt:
        DateTime.tryParse('${json['nextAllowedAt']}') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    reason: RefreshBlockReason.values.firstWhere(
      (value) => value.name == json['reason'],
      orElse: () => RefreshBlockReason.recentSuccess,
    ),
  );

  final DateTime nextAllowedAt;
  final RefreshBlockReason reason;

  Map<String, dynamic> toJson() => {
    'nextAllowedAt': nextAllowedAt.toIso8601String(),
    'reason': reason.name,
  };
}
