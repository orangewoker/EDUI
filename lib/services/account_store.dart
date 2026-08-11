import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/monitor_account.dart';
import '../models/quota_snapshot.dart';

class AccountStore {
  AccountStore({
    FlutterSecureStorage? secureStorage,
    Future<SharedPreferences>? preferences,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       _preferences = preferences ?? SharedPreferences.getInstance();

  final FlutterSecureStorage _secureStorage;
  final Future<SharedPreferences> _preferences;

  static const _accountsKey = 'monitor_accounts_v1';
  static const _snapshotsKey = 'quota_snapshots_v1';

  Future<List<MonitorAccount>> loadAccounts() async {
    final prefs = await _preferences;
    final raw = prefs.getString(_accountsKey);
    if (raw == null || raw.isEmpty) {
      final defaults = [MonitorAccount.amdDefault()];
      await saveAccounts(defaults);
      return defaults;
    }
    try {
      return MonitorAccount.decodeList(raw);
    } catch (_) {
      return [MonitorAccount.amdDefault()];
    }
  }

  Future<void> saveAccounts(List<MonitorAccount> accounts) async {
    final prefs = await _preferences;
    await prefs.setString(_accountsKey, MonitorAccount.encodeList(accounts));
  }

  Future<List<QuotaSnapshot>> loadSnapshots() async {
    final prefs = await _preferences;
    final raw = prefs.getString(_snapshotsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .whereType<Map>()
          .map(
            (item) => QuotaSnapshot.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveSnapshots(List<QuotaSnapshot> snapshots) async {
    final prefs = await _preferences;
    await prefs.setString(
      _snapshotsKey,
      jsonEncode(snapshots.map((item) => item.toJson()).toList()),
    );
  }

  Future<String> readApiKey(String accountId) => _secureStorage
      .read(key: 'api_key.$accountId')
      .then((value) => value ?? '');

  Future<String> readCookie(String accountId) => _secureStorage
      .read(key: 'cookie.$accountId')
      .then((value) => value ?? '');

  Future<String> readCredential(MonitorAccount account) =>
      account.authenticationType == AuthenticationType.manualCookie
      ? readCookie(account.id)
      : readApiKey(account.id);

  Future<void> writeApiKey(String accountId, String value) async {
    if (value.trim().isEmpty) return;
    await _secureStorage.write(key: 'api_key.$accountId', value: value.trim());
  }

  Future<void> writeCookie(String accountId, String value) async {
    if (value.trim().isEmpty) return;
    await _secureStorage.write(key: 'cookie.$accountId', value: value.trim());
  }

  Future<void> writeCredential(MonitorAccount account, String value) =>
      account.authenticationType == AuthenticationType.manualCookie
      ? writeCookie(account.id, value)
      : writeApiKey(account.id, value);

  Future<bool> hasApiKey(String accountId) async =>
      (await readApiKey(accountId)).isNotEmpty;

  Future<bool> hasCredential(MonitorAccount account) async =>
      (await readCredential(account)).isNotEmpty;

  Future<void> deleteAccountSecrets(String accountId) async {
    await Future.wait([
      _secureStorage.delete(key: 'api_key.$accountId'),
      _secureStorage.delete(key: 'cookie.$accountId'),
    ]);
  }
}
