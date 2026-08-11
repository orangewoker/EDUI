import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/monitor_account.dart';
import '../models/quota_snapshot.dart';

class QuotaClient {
  QuotaClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<QuotaSnapshot> refresh(
    MonitorAccount account,
    String credential,
  ) async {
    final key = credential.trim();
    if (key.isEmpty) {
      throw QuotaException(
        account.authenticationType == AuthenticationType.manualCookie
            ? '请先填写 Cookie'
            : '请先填写 API Key',
      );
    }
    return switch (account.providerType) {
      ProviderType.openAI => _refreshOpenAI(account, key),
      ProviderType.sub2Api => _refreshSub2Api(account, key),
      ProviderType.amdRadeon => _refreshOpenAICompatible(account, key),
      ProviderType.deepSeek => _refreshDeepSeek(account, key),
      ProviderType.customJson => _refreshCustom(account, key),
    };
  }

  Future<QuotaSnapshot> _refreshOpenAI(
    MonitorAccount account,
    String adminKey,
  ) async {
    final now = DateTime.now();
    final startTime = now.subtract(const Duration(days: 30));
    final uri = _endpoint(account.baseUrl, 'organization/costs').replace(
      queryParameters: {
        'start_time': '${startTime.millisecondsSinceEpoch ~/ 1000}',
        'end_time': '${now.millisecondsSinceEpoch ~/ 1000}',
        'bucket_width': '1d',
        'limit': '30',
      },
    );
    final response = await _client
        .get(uri, headers: _headers(account, adminKey))
        .timeout(const Duration(seconds: 30));
    _requireSuccess(response);
    final body = jsonDecode(response.body);
    final buckets = body is Map ? body['data'] : null;
    if (buckets is! List) {
      throw const QuotaException('OpenAI Costs 响应缺少 data');
    }
    var total = 0.0;
    String currency = 'usd';
    for (final bucket in buckets.whereType<Map>()) {
      final results = bucket['results'];
      if (results is! List) continue;
      for (final result in results.whereType<Map>()) {
        final amount = result['amount'];
        if (amount is! Map) continue;
        total += double.tryParse('${amount['value'] ?? ''}') ?? 0;
        final valueCurrency = '${amount['currency'] ?? ''}'.trim();
        if (valueCurrency.isNotEmpty) currency = valueCurrency;
      }
    }
    final budget = account.budgetLimit;
    final hasBudget = budget != null && budget > 0;
    return QuotaSnapshot(
      accountId: account.id,
      accountName: account.name,
      remaining: hasBudget
          ? (budget - total).clamp(0.0, budget).toDouble()
          : total,
      limit: hasBudget ? budget : null,
      used: total,
      unit: hasBudget
          ? currency.toUpperCase()
          : '${currency.toUpperCase()}/30天已用',
      updatedAt: now,
      message: hasBudget
          ? '按设置的预算减去 OpenAI 官方 Costs API 最近 30 天用量'
          : '通过 OpenAI 官方 Costs API 汇总最近 30 天用量',
    );
  }

  Future<QuotaSnapshot> _refreshOpenAICompatible(
    MonitorAccount account,
    String apiKey,
  ) async {
    // Sub2API exposes the user's actual wallet/subscription balance through
    // GET /v1/usage. Try that first so existing OpenAI-compatible accounts do
    // not need to be recreated or manually configured.
    final sub2ApiSnapshot = await _tryRefreshSub2Api(account, apiKey);
    if (sub2ApiSnapshot != null) return sub2ApiSnapshot;

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

  Future<QuotaSnapshot> _refreshSub2Api(
    MonitorAccount account,
    String apiKey,
  ) async {
    final response = await _sub2ApiUsageResponse(
      account.baseUrl,
      apiKey,
      strict: true,
    );
    if (response == null) {
      throw const QuotaException('未找到 Sub2API /v1/usage 余额接口，请检查站点地址和 API Key');
    }
    return _parseSub2ApiUsage(account, response);
  }

  Future<QuotaSnapshot?> _tryRefreshSub2Api(
    MonitorAccount account,
    String apiKey,
  ) async {
    final response = await _sub2ApiUsageResponse(
      account.baseUrl,
      apiKey,
      strict: false,
    );
    return response == null ? null : _parseSub2ApiUsage(account, response);
  }

  Future<http.Response?> _sub2ApiUsageResponse(
    String baseUrl,
    String apiKey, {
    required bool strict,
  }) async {
    final candidates = _sub2ApiUsageCandidates(baseUrl);
    QuotaException? lastError;
    for (final uri in candidates) {
      try {
        final response = await _client
            .get(uri, headers: _apiKeyHeaders(apiKey))
            .timeout(Duration(seconds: strict ? 30 : 8));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final body = _decodeObject(response.body);
          if (body != null && _looksLikeSub2ApiUsage(body)) return response;
          continue;
        }
        if (response.statusCode == 404 || response.statusCode == 405) continue;
        if (strict) {
          _requireSuccess(response);
        }
      } on QuotaException catch (error) {
        lastError = error;
        if (strict) rethrow;
      } catch (error) {
        if (strict) {
          throw QuotaException('读取 Sub2API 余额失败：$error');
        }
      }
    }
    if (strict && lastError != null) throw lastError;
    return null;
  }

  List<Uri> _sub2ApiUsageCandidates(String baseUrl) {
    final normalized = baseUrl.replaceFirst(RegExp(r'/+$'), '');
    final parsed = Uri.parse(normalized);
    final path = parsed.path.replaceFirst(RegExp(r'/+$'), '');
    if (path.toLowerCase().endsWith('/v1')) {
      return [_endpoint(normalized, 'usage')];
    }
    return [_endpoint(normalized, 'v1/usage')];
  }

  QuotaSnapshot _parseSub2ApiUsage(
    MonitorAccount account,
    http.Response response,
  ) {
    final body = _decodeObject(response.body);
    if (body == null) {
      throw const QuotaException('Sub2API 余额接口返回的不是 JSON');
    }
    final quota = body['quota'] is Map
        ? Map<String, dynamic>.from(body['quota'] as Map)
        : const <String, dynamic>{};
    final rateLimits = body['rate_limits'] is List
        ? (body['rate_limits'] as List).whereType<Map>().toList()
        : const <Map>[];
    final firstRateLimit = rateLimits.isEmpty
        ? const <String, dynamic>{}
        : Map<String, dynamic>.from(rateLimits.first);
    final remaining = _numberFrom(
      body['remaining'] ??
          quota['remaining'] ??
          body['balance'] ??
          firstRateLimit['remaining'],
    );
    if (remaining == null) {
      throw const QuotaException('Sub2API 余额响应缺少 remaining/balance');
    }

    var limit =
        _numberFrom(quota['limit']) ?? _numberFrom(firstRateLimit['limit']);
    var used =
        _numberFrom(quota['used']) ?? _numberFrom(firstRateLimit['used']);
    final resetAt = _dateFrom(quota['reset_at'] ?? firstRateLimit['reset_at']);
    final mode = '${body['mode'] ?? ''}'.trim();
    final planName = '${body['planName'] ?? ''}'.trim();
    final unit = '${body['unit'] ?? account.unit}'.trim();
    final message = [
      'Sub2API /v1/usage',
      if (planName.isNotEmpty) planName,
      if (mode == 'quota_limited') 'API Key 配额',
      if (mode == 'unrestricted' && planName.isEmpty) '账户余额',
    ].join(' · ');
    return QuotaSnapshot(
      accountId: account.id,
      accountName: account.name,
      remaining: remaining,
      limit: limit,
      used: used,
      unit: unit.isEmpty ? 'USD' : unit,
      updatedAt: DateTime.now(),
      resetAt: resetAt,
      message: message,
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
          headers: _headers(account, apiKey),
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
    final tokenLimit = _doubleHeader(headers, 'x-ratelimit-limit-tokens');
    final tokenRemaining = _doubleHeader(
      headers,
      'x-ratelimit-remaining-tokens',
    );
    final requestLimit =
        _intHeader(headers, 'x-ratelimit-limit-user-rpm') ??
        _intHeader(headers, 'x-ratelimit-limit-requests');
    final requestRemaining =
        _intHeader(headers, 'x-ratelimit-remaining-user-rpm') ??
        _intHeader(headers, 'x-ratelimit-remaining-requests');
    if (remaining == null && limit == null && tokenRemaining == null) {
      throw const QuotaException('服务响应成功，但没有返回可识别的额度头（支持 USD、Token 或请求数）');
    }
    final tokenQuota = remaining == null && limit == null;
    final resetSeconds = _intHeader(
      headers,
      'x-ratelimit-reset-user-daily-usd',
    );
    return QuotaSnapshot(
      accountId: account.id,
      accountName: account.name,
      remaining: tokenQuota
          ? tokenRemaining!
          : remaining ?? ((limit ?? 0) - (used ?? 0)),
      limit: tokenQuota ? tokenLimit : limit,
      used: tokenQuota
          ? (tokenLimit == null ? null : tokenLimit - tokenRemaining!)
          : used ??
                (limit != null && remaining != null ? limit - remaining : null),
      unit: tokenQuota ? 'Tokens' : 'USD/日',
      updatedAt: DateTime.now(),
      resetAt: resetSeconds == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(resetSeconds * 1000),
      requestLimit: requestLimit,
      requestRemaining: requestRemaining,
      message: tokenQuota ? '服务未提供美元余额，已自动显示 Token 和请求额度' : '通过一次最小响应探测读取额度响应头',
    );
  }

  Future<List<String>> _availableModels(String baseUrl, String apiKey) async {
    final response = await _client
        .get(_endpoint(baseUrl, 'models'), headers: _apiKeyHeaders(apiKey))
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
          headers: _headers(account, apiKey),
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
          headers: _headers(account, apiKey),
        )
        .timeout(const Duration(seconds: 30));
    _requireSuccess(response);
    final body = jsonDecode(response.body);
    final rawValue = _numberAt(body, account.balanceField);
    var limit = account.limitField.trim().isEmpty
        ? null
        : _numberAt(body, account.limitField);
    if (rawValue == null) {
      throw QuotaException('无法读取字段：${account.balanceField}');
    }
    late final double remaining;
    late final double? used;
    switch (account.metricValueMode) {
      case MetricValueMode.remaining:
        remaining = rawValue;
        used = limit == null ? null : limit - remaining;
        break;
      case MetricValueMode.used:
        if (limit == null) {
          throw const QuotaException('额度字段是已用额度时，必须配置总额度字段');
        }
        used = rawValue;
        remaining = (limit - used).clamp(0.0, limit).toDouble();
        break;
      case MetricValueMode.usedPercent:
        limit = 100;
        used = rawValue.clamp(0.0, 100.0).toDouble();
        remaining = 100 - used;
        break;
    }
    return QuotaSnapshot(
      accountId: account.id,
      accountName: account.name,
      remaining: remaining,
      limit: limit,
      used: used,
      unit: account.unit,
      updatedAt: DateTime.now(),
      resetAt: account.resetField.trim().isEmpty
          ? null
          : _dateAt(body, account.resetField),
    );
  }

  Map<String, String> _headers(MonitorAccount account, String credential) =>
      account.authenticationType == AuthenticationType.manualCookie
      ? {
          'Cookie': credential,
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        }
      : _apiKeyHeaders(credential);

  Map<String, String> _apiKeyHeaders(String apiKey) => {
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
      double.tryParse(_header(headers, name) ?? '');

  int? _intHeader(Map<String, String> headers, String name) =>
      int.tryParse(_header(headers, name)?.split('.').first ?? '');

  String? _header(Map<String, String> headers, String name) {
    final expected = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == expected) return entry.value;
    }
    return null;
  }

  double? _numberAt(dynamic source, String path) {
    final current = _valueAt(source, path);
    return current is num ? current.toDouble() : double.tryParse('$current');
  }

  DateTime? _dateAt(dynamic source, String path) {
    final value = _valueAt(source, path);
    if (value is num) {
      final raw = value.toInt();
      return DateTime.fromMillisecondsSinceEpoch(
        raw.abs() >= 100000000000 ? raw : raw * 1000,
      );
    }
    final raw = '$value'.trim();
    final numeric = int.tryParse(raw);
    if (numeric != null) {
      return DateTime.fromMillisecondsSinceEpoch(
        numeric.abs() >= 100000000000 ? numeric : numeric * 1000,
      );
    }
    return DateTime.tryParse(raw);
  }

  dynamic _valueAt(dynamic source, String path) {
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
    return current;
  }

  Map<String, dynamic>? _decodeObject(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  bool _looksLikeSub2ApiUsage(Map<String, dynamic> body) =>
      body.containsKey('remaining') ||
      body.containsKey('balance') ||
      body['quota'] is Map ||
      body['mode'] == 'unrestricted' ||
      body['mode'] == 'quota_limited';

  double? _numberFrom(dynamic value) =>
      value is num ? value.toDouble() : double.tryParse('$value');

  DateTime? _dateFrom(dynamic value) {
    if (value == null) return null;
    if (value is num) {
      final raw = value.toInt();
      return DateTime.fromMillisecondsSinceEpoch(
        raw.abs() >= 100000000000 ? raw : raw * 1000,
      );
    }
    final raw = '$value'.trim();
    final numeric = int.tryParse(raw);
    if (numeric != null) {
      return DateTime.fromMillisecondsSinceEpoch(
        numeric.abs() >= 100000000000 ? numeric : numeric * 1000,
      );
    }
    return DateTime.tryParse(raw);
  }
}

class QuotaException implements Exception {
  const QuotaException(this.message, {this.canTryNextModel = false});
  final String message;
  final bool canTryNextModel;
  @override
  String toString() => message;
}
