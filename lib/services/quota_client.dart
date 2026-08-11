import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/monitor_account.dart';
import '../models/quota_snapshot.dart';

class QuotaClient {
  QuotaClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<QuotaSnapshot> refresh(MonitorAccount account, String apiKey) async {
    final key = apiKey.trim();
    if (key.isEmpty) throw const QuotaException('请先填写 API Key');
    return switch (account.providerType) {
      ProviderType.amdRadeon => _refreshOpenAICompatible(account, key),
      ProviderType.deepSeek => _refreshDeepSeek(account, key),
      ProviderType.customJson => _refreshCustom(account, key),
    };
  }

  Future<QuotaSnapshot> _refreshOpenAICompatible(
    MonitorAccount account,
    String apiKey,
  ) async {
    final models = await _availableModels(account.baseUrl, apiKey);
    if (models.isEmpty) {
      throw const QuotaException('服务的 /models 没有返回可用模型');
    }
    QuotaException? lastError;
    for (final model in models.take(12)) {
      try {
        return await _probeOpenAICompatible(account, apiKey, model);
      } on QuotaException catch (error) {
        lastError = error;
        if (!error.canTryNextModel) rethrow;
      }
    }
    throw QuotaException(
      '自动尝试了 ${models.take(12).length} 个模型，均不可用：${lastError?.message ?? '未知错误'}',
    );
  }

  Future<QuotaSnapshot> _probeOpenAICompatible(
    MonitorAccount account,
    String apiKey,
    String model,
  ) async {
    final uri = _endpoint(account.baseUrl, 'chat/completions');
    final response = await _client
        .post(
          uri,
          headers: _headers(apiKey),
          body: jsonEncode({
            'model': model,
            'messages': const [
              {'role': 'user', 'content': 'Reply with a single dot.'},
            ],
            'max_tokens': 1,
            'stream': false,
          }),
        )
        .timeout(const Duration(seconds: 60));
    _requireSuccess(response, allowModelFallback: true);

    final headers = response.headers;
    final limit = _doubleHeader(headers, 'x-ratelimit-limit-user-daily-usd');
    final remaining = _doubleHeader(
      headers,
      'x-ratelimit-remaining-user-daily-usd',
    );
    final used = _doubleHeader(headers, 'x-ratelimit-used-user-daily-usd');
    if (remaining == null && limit == null) {
      throw const QuotaException('服务响应成功，但没有返回额度响应头');
    }
    final resetSeconds = _intHeader(
      headers,
      'x-ratelimit-reset-user-daily-usd',
    );
    return QuotaSnapshot(
      accountId: account.id,
      accountName: account.name,
      remaining: remaining ?? ((limit ?? 0) - (used ?? 0)),
      limit: limit,
      used:
          used ??
          (limit != null && remaining != null ? limit - remaining : null),
      unit: 'USD/日',
      updatedAt: DateTime.now(),
      resetAt: resetSeconds == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(resetSeconds * 1000),
      requestLimit: _intHeader(headers, 'x-ratelimit-limit-user-rpm'),
      requestRemaining: _intHeader(headers, 'x-ratelimit-remaining-user-rpm'),
      message: '通过一次最小响应探测读取额度响应头',
    );
  }

  Future<List<String>> _availableModels(String baseUrl, String apiKey) async {
    final response = await _client
        .get(_endpoint(baseUrl, 'models'), headers: _headers(apiKey))
        .timeout(const Duration(seconds: 30));
    _requireSuccess(response);
    final body = jsonDecode(response.body);
    final data = body is Map ? body['data'] : null;
    if (data is! List) return [];
    return data
        .whereType<Map>()
        .map((item) => '${item['id'] ?? ''}'.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
  }

  Future<QuotaSnapshot> _refreshDeepSeek(
    MonitorAccount account,
    String apiKey,
  ) async {
    final response = await _client
        .get(
          _endpoint(account.baseUrl, 'user/balance'),
          headers: _headers(apiKey),
        )
        .timeout(const Duration(seconds: 30));
    _requireSuccess(response);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final infos = body['balance_infos'];
    if (infos is! List || infos.isEmpty || infos.first is! Map) {
      throw const QuotaException('余额响应缺少 balance_infos');
    }
    final first = Map<String, dynamic>.from(infos.first as Map);
    final value = double.tryParse('${first['total_balance']}');
    if (value == null) throw const QuotaException('无法解析 DeepSeek 余额');
    return QuotaSnapshot(
      accountId: account.id,
      accountName: account.name,
      remaining: value,
      unit: '${first['currency'] ?? account.unit}',
      updatedAt: DateTime.now(),
      message: body['is_available'] == false ? '当前余额不可用' : '余额可用',
    );
  }

  Future<QuotaSnapshot> _refreshCustom(
    MonitorAccount account,
    String apiKey,
  ) async {
    final response = await _client
        .get(
          _endpoint(account.baseUrl, account.endpointPath),
          headers: _headers(apiKey),
        )
        .timeout(const Duration(seconds: 30));
    _requireSuccess(response);
    final body = jsonDecode(response.body);
    final remaining = _numberAt(body, account.balanceField);
    final limit = account.limitField.trim().isEmpty
        ? null
        : _numberAt(body, account.limitField);
    if (remaining == null) {
      throw QuotaException('无法读取字段：${account.balanceField}');
    }
    return QuotaSnapshot(
      accountId: account.id,
      accountName: account.name,
      remaining: remaining,
      limit: limit,
      used: limit == null ? null : limit - remaining,
      unit: account.unit,
      updatedAt: DateTime.now(),
    );
  }

  Map<String, String> _headers(String apiKey) => {
    'Authorization': 'Bearer $apiKey',
    'Accept': 'application/json',
    'Content-Type': 'application/json',
  };

  Uri _endpoint(String base, String path) => Uri.parse(
    '${base.replaceAll(RegExp(r'/+$'), '')}/${path.replaceAll(RegExp(r'^/+'), '')}',
  );

  void _requireSuccess(
    http.Response response, {
    bool allowModelFallback = false,
  }) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    var detail = response.body.trim();
    try {
      final body = jsonDecode(detail);
      if (body is Map) {
        detail =
            '${body['error'] is Map ? body['error']['message'] : body['detail'] ?? body['message'] ?? detail}';
      }
    } catch (_) {}
    if (detail.length > 240) detail = '${detail.substring(0, 240)}…';
    final lower = detail.toLowerCase();
    final canTryNextModel =
        allowModelFallback &&
        response.statusCode != 401 &&
        response.statusCode != 403 &&
        response.statusCode != 429 &&
        (response.statusCode >= 500 ||
            lower.contains('model') ||
            lower.contains('not available') ||
            lower.contains('not found'));
    throw QuotaException(
      'HTTP ${response.statusCode}：$detail',
      canTryNextModel: canTryNextModel,
    );
  }

  double? _doubleHeader(Map<String, String> headers, String name) =>
      double.tryParse(headers[name] ?? '');

  int? _intHeader(Map<String, String> headers, String name) =>
      int.tryParse(headers[name]?.split('.').first ?? '');

  double? _numberAt(dynamic source, String path) {
    dynamic current = source;
    for (final segment in path.split('.').where((item) => item.isNotEmpty)) {
      if (current is Map && current.containsKey(segment)) {
        current = current[segment];
      } else if (current is List && int.tryParse(segment) != null) {
        final index = int.parse(segment);
        if (index < 0 || index >= current.length) return null;
        current = current[index];
      } else {
        return null;
      }
    }
    return current is num ? current.toDouble() : double.tryParse('$current');
  }
}

class QuotaException implements Exception {
  const QuotaException(this.message, {this.canTryNextModel = false});
  final String message;
  final bool canTryNextModel;
  @override
  String toString() => message;
}
