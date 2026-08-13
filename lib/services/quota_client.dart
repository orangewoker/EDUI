import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/monitor_account.dart';
import '../models/quota_snapshot.dart';
import 'codex_oauth_credential.dart';
import 'new_api_credential.dart';

class QuotaClient {
  QuotaClient({
    http.Client? client,
    this._retryDelays = const [
      Duration(milliseconds: 600),
      Duration(milliseconds: 1400),
    ],
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final List<Duration> _retryDelays;

  Future<QuotaSnapshot> refresh(
    MonitorAccount account,
    String credential,
  ) async {
    final key = credential.trim();
    if (key.isEmpty) {
      throw QuotaException(
        account.authenticationType == AuthenticationType.manualCookie
            ? '请先填写 Cookie 或 Codex 导出 JSON'
            : '请先填写 API Key',
        kind: QuotaErrorKind.authentication,
      );
    }
    for (var attempt = 0; ; attempt++) {
      try {
        return await switch (account.providerType) {
          ProviderType.openAI => _refreshOpenAI(account, key),
          ProviderType.sub2Api => _refreshSub2Api(account, key),
          ProviderType.amdRadeon => _refreshOpenAICompatible(account, key),
          ProviderType.deepSeek => _refreshDeepSeek(account, key),
          ProviderType.customJson => _refreshCustom(account, key),
        };
      } catch (error) {
        if (!_isTransientNetworkError(error)) rethrow;
        if (attempt >= _retryDelays.length) {
          final host = Uri.tryParse(account.baseUrl)?.host ?? '';
          final target = host.isEmpty ? '服务站点' : host;
          throw QuotaException(
            '暂时无法连接 $target，已自动重试 ${_retryDelays.length} 次。请稍后再试，或检查网络与代理。',
            kind: QuotaErrorKind.network,
          );
        }
        await Future<void>.delayed(_retryDelays[attempt]);
      }
    }
  }

  bool _isTransientNetworkError(Object error) {
    if (error is SocketException || error is TimeoutException) return true;
    if (error is http.ClientException) {
      final message = error.message.toLowerCase();
      return message.contains('socketexception') ||
          message.contains('connection refused') ||
          message.contains('connection reset') ||
          message.contains('connection closed') ||
          message.contains('failed host lookup') ||
          message.contains('network is unreachable') ||
          message.contains('software caused connection abort');
    }
    return false;
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
    String rawCredential,
  ) async {
    final credential = NewApiCredential.parse(rawCredential);
    final apiKey = credential.apiKey;
    if (apiKey.isEmpty) {
      throw const QuotaException(
        '请先填写 API Key',
        kind: QuotaErrorKind.authentication,
      );
    }
    // Prefer read-only balance endpoints before sending a minimal chat probe.
    // This covers Sub2API and New API / One API relays without requiring a
    // model selection or consuming tokens.
    final sub2ApiSnapshot = await _tryRefreshSub2Api(account, apiKey);
    if (sub2ApiSnapshot != null) return sub2ApiSnapshot;
    final newApiSnapshot = await _tryRefreshNewApi(
      account,
      apiKey,
      dashboardToken: credential.dashboardToken,
    );
    if (newApiSnapshot != null) return newApiSnapshot;

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
    String rawCredential,
  ) async {
    final credential = NewApiCredential.parse(rawCredential);
    final apiKey = credential.apiKey;
    if (apiKey.isEmpty) {
      throw const QuotaException(
        '请先填写 API Key',
        kind: QuotaErrorKind.authentication,
      );
    }
    final response = await _sub2ApiUsageResponse(
      account.baseUrl,
      apiKey,
      strict: true,
    );
    if (response == null) {
      final newApiSnapshot = await _tryRefreshNewApi(
        account,
        apiKey,
        dashboardToken: credential.dashboardToken,
      );
      if (newApiSnapshot != null) return newApiSnapshot;
      throw const QuotaException(
        '未找到 Sub2API /v1/usage 或 New API 余额接口，请检查站点地址和 API Key',
      );
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
          if (_isTransientNetworkError(error)) rethrow;
          throw QuotaException(
            '读取 Sub2API 余额失败：$error',
            kind: QuotaErrorKind.server,
          );
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

  Future<QuotaSnapshot?> _tryRefreshNewApi(
    MonitorAccount account,
    String apiKey, {
    String dashboardToken = '',
  }) async {
    final display = await _readNewApiDisplayConfig(account.baseUrl);
    if (display == null) return null;

    if (dashboardToken.isNotEmpty) {
      final wallet = await _tryRefreshNewApiUserBalance(
        account,
        dashboardToken,
        display,
      );
      if (wallet != null) return wallet;
    }

    // `unlimited_quota` is scoped to the API key. It does not mean that the
    // owning user has an unlimited wallet, so keep looking for account data.
    final tokenUsage = await _tryRefreshNewApiTokenUsage(
      account,
      apiKey,
      display,
    );
    if (tokenUsage?.snapshot != null) return tokenUsage!.snapshot;
    final unlimitedKey = tokenUsage?.unlimited == true;

    for (final endpoints in _newApiBillingCandidates(account.baseUrl)) {
      try {
        final responses = await Future.wait([
          _client
              .get(endpoints.subscription, headers: _apiKeyHeaders(apiKey))
              .timeout(const Duration(seconds: 8)),
          _client
              .get(endpoints.usage, headers: _apiKeyHeaders(apiKey))
              .timeout(const Duration(seconds: 8)),
        ]);
        final subscriptionResponse = responses[0];
        final usageResponse = responses[1];
        if (!_isSuccess(subscriptionResponse) || !_isSuccess(usageResponse)) {
          continue;
        }
        final subscription = _decodeObject(subscriptionResponse.body);
        final usage = _decodeObject(usageResponse.body);
        if (subscription == null ||
            usage == null ||
            subscription['error'] != null ||
            usage['error'] != null) {
          continue;
        }
        final limit = _numberFrom(
          subscription['hard_limit_usd'] ??
              subscription['system_hard_limit_usd'] ??
              subscription['soft_limit_usd'],
        );
        final totalUsage = _numberFrom(usage['total_usage']);
        if (limit == null || totalUsage == null) continue;

        // New API intentionally returns this sentinel when an unlimited key
        // is shown in key-stat mode. It is not the user's wallet balance.
        if (unlimitedKey && limit >= 99999999) continue;

        final used = totalUsage / 100;
        final remaining = (limit - used).clamp(0.0, double.infinity);
        final accessUntil = _numberFrom(subscription['access_until']);
        return QuotaSnapshot(
          accountId: account.id,
          accountName: account.name,
          remaining: remaining,
          limit: limit,
          used: used,
          unit: display.unit,
          updatedAt: DateTime.now(),
          resetAt: accessUntil == null || accessUntil <= 0
              ? null
              : _dateFrom(accessUntil),
          message: 'New API / One API 账户余额',
        );
      } catch (_) {
        // A non-New-API relay may return HTML, reject the route, or time out.
        // Continue to the next known path and eventually use header probing.
      }
    }

    if (unlimitedKey) {
      throw const QuotaException(
        '这个 New API Key 是“不单独限额”，但站点没有通过普通 Key 返回用户余额。请编辑账户并补充 New API 控制台的登录 Token / PAT。',
        kind: QuotaErrorKind.configuration,
      );
    }
    return null;
  }

  Future<_NewApiTokenUsageResult?> _tryRefreshNewApiTokenUsage(
    MonitorAccount account,
    String apiKey,
    _NewApiDisplayConfig display,
  ) async {
    final quotaPerUnit = display.quotaPerUnit;
    if (!display.usesRawTokens && (quotaPerUnit == null || quotaPerUnit <= 0)) {
      return null;
    }
    try {
      // Keep the trailing slash. Some New API deployments redirect the path
      // without it, and a redirect can drop the Authorization header.
      final uri = _endpoint(
        _newApiPanelRoot(account.baseUrl).toString(),
        'api/usage/token/',
      );
      final response = await _client
          .get(uri, headers: _apiKeyHeaders(apiKey))
          .timeout(const Duration(seconds: 8));
      if (!_isSuccess(response)) return null;
      final body = _decodeObject(response.body);
      final data = body?['data'];
      if (body == null ||
          body['error'] != null ||
          data is! Map ||
          data['object'] != 'token_usage') {
        return null;
      }
      if (data['unlimited_quota'] == true) {
        return const _NewApiTokenUsageResult(unlimited: true);
      }
      final availableRaw = _numberFrom(data['total_available']);
      final grantedRaw = _numberFrom(data['total_granted']);
      final usedRaw = _numberFrom(data['total_used']);
      if (availableRaw == null) return null;

      final remaining = display.convertQuota(availableRaw);
      final limit = grantedRaw == null
          ? null
          : display.convertQuota(grantedRaw);
      final used = usedRaw == null ? null : display.convertQuota(usedRaw);
      if (remaining == null) return null;
      final expiresAt = _numberFrom(data['expires_at']);
      return _NewApiTokenUsageResult(
        unlimited: false,
        snapshot: QuotaSnapshot(
          accountId: account.id,
          accountName: account.name,
          remaining: remaining.clamp(0.0, double.infinity),
          limit: limit,
          used: used,
          unit: display.unit,
          updatedAt: DateTime.now(),
          resetAt: expiresAt == null || expiresAt <= 0
              ? null
              : _dateFrom(expiresAt),
          message: 'New API Key 余额',
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<QuotaSnapshot?> _tryRefreshNewApiUserBalance(
    MonitorAccount account,
    String dashboardToken,
    _NewApiDisplayConfig display,
  ) async {
    final uri = _endpoint(
      _newApiPanelRoot(account.baseUrl).toString(),
      'api/user/self',
    );
    final response = await _client
        .get(uri, headers: _apiKeyHeaders(dashboardToken))
        .timeout(const Duration(seconds: 8));
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const QuotaException(
        'New API 登录 Token / PAT 无效或已过期',
        kind: QuotaErrorKind.authentication,
      );
    }
    if (!_isSuccess(response)) return null;
    final body = _decodeObject(response.body);
    final rawData = body?['data'];
    if (body == null || body['success'] == false || rawData is! Map) {
      return null;
    }
    final data = Map<String, dynamic>.from(rawData);
    final quotaRaw = _numberFrom(data['quota']);
    if (quotaRaw == null) return null;
    final usedRaw = _numberFrom(data['used_quota']);
    final remaining = display.convertQuota(quotaRaw);
    final used = usedRaw == null ? null : display.convertQuota(usedRaw);
    if (remaining == null) return null;
    return QuotaSnapshot(
      accountId: account.id,
      accountName: account.name,
      remaining: remaining.clamp(0.0, double.infinity),
      limit: used == null ? null : remaining + used,
      used: used,
      unit: display.unit,
      updatedAt: DateTime.now(),
      message: 'New API 用户账户余额',
    );
  }

  Future<_NewApiDisplayConfig?> _readNewApiDisplayConfig(String baseUrl) async {
    try {
      final uri = _endpoint(_newApiPanelRoot(baseUrl).toString(), 'api/status');
      final response = await _client
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 6));
      if (!_isSuccess(response)) return null;
      final body = _decodeObject(response.body);
      final rawData = body?['data'];
      if (body == null || rawData is! Map) return null;
      final data = Map<String, dynamic>.from(rawData);
      final looksLikeNewApi =
          data.containsKey('quota_per_unit') ||
          data.containsKey('quota_display_type') ||
          data.containsKey('display_in_currency');
      if (!looksLikeNewApi) return null;
      return _NewApiDisplayConfig.fromStatus(data);
    } catch (_) {
      return null;
    }
  }

  List<_NewApiBillingEndpoints> _newApiBillingCandidates(String baseUrl) {
    final root = _newApiPanelRoot(baseUrl).toString();
    return [
      _NewApiBillingEndpoints(
        subscription: _endpoint(root, 'v1/dashboard/billing/subscription'),
        usage: _endpoint(root, 'v1/dashboard/billing/usage'),
      ),
      _NewApiBillingEndpoints(
        subscription: _endpoint(root, 'dashboard/billing/subscription'),
        usage: _endpoint(root, 'dashboard/billing/usage'),
      ),
    ];
  }

  Uri _newApiPanelRoot(String baseUrl) {
    final parsed = Uri.parse(baseUrl.trim());
    var path = parsed.path.replaceFirst(RegExp(r'/+$'), '');
    if (path.toLowerCase().endsWith('/v1')) {
      path = path.substring(0, path.length - 3);
    }
    return parsed.replace(path: path, query: null, fragment: null);
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
    final credential = CodexOAuthCredential.tryParse(apiKey);
    final codexSnapshot = _parseCodexRateLimits(
      account,
      body,
      credential: credential,
    );
    if (codexSnapshot != null) return codexSnapshot;
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
      quotaWindows: account.metricValueMode == MetricValueMode.usedPercent
          ? [
              QuotaWindow(
                label: '额度',
                remainingPercent: remaining,
                resetAt: account.resetField.trim().isEmpty
                    ? null
                    : _dateAt(body, account.resetField),
              ),
            ]
          : const [],
    );
  }

  QuotaSnapshot? _parseCodexRateLimits(
    MonitorAccount account,
    dynamic body, {
    CodexOAuthCredential? credential,
  }) {
    if (body is! Map || body['rate_limit'] is! Map) return null;
    final rateLimit = Map<String, dynamic>.from(body['rate_limit'] as Map);
    final responsePlanType = CodexOAuthCredential.normalizePlanType(
      body['plan_type'] ??
          body['chatgpt_plan_type'] ??
          rateLimit['plan_type'] ??
          rateLimit['chatgpt_plan_type'],
    );
    final planType = credential?.planType ?? responsePlanType;
    final planLabel = credential?.planLabel ?? _planLabel(planType);
    final weeklyPrimary = planType == 'plus' || planType == 'pro';
    final primaryWindow = _codexWindow(
      rateLimit['primary_window'],
      weeklyPrimary ? '本周额度' : '5 小时额度',
    );
    final secondaryWindow = _codexWindow(rateLimit['secondary_window'], '本周额度');
    final weeklyWindow = primaryWindow ?? secondaryWindow;
    final windows = weeklyPrimary
        ? <QuotaWindow>[?weeklyWindow]
        : <QuotaWindow>[?primaryWindow, ?secondaryWindow];
    if (windows.isEmpty) return null;

    final primary = windows.first;
    final used = (100 - primary.remainingPercent).clamp(0.0, 100.0);
    return QuotaSnapshot(
      accountId: account.id,
      accountName: account.name,
      remaining: primary.remainingPercent,
      limit: 100,
      used: used,
      unit: '%',
      updatedAt: DateTime.now(),
      resetAt: primary.resetAt,
      message: windows.length > 1 ? 'Codex 5 小时与本周额度' : '${primary.label}剩余',
      planLabel: planLabel,
      quotaWindows: windows,
    );
  }

  String? _planLabel(String? planType) => switch (planType) {
    'plus' => 'PLUS',
    'pro' => 'PRO',
    'k12' => 'K12',
    'free' => 'FREE',
    'team' => 'TEAM',
    'business' => 'BUSINESS',
    'enterprise' => 'ENTERPRISE',
    'edu' => 'EDU',
    final value? when value.isNotEmpty => value.toUpperCase(),
    _ => null,
  };

  QuotaWindow? _codexWindow(dynamic source, String label) {
    if (source is! Map) return null;
    final window = Map<String, dynamic>.from(source);
    final usedPercent = _numberFrom(window['used_percent']);
    if (usedPercent == null) return null;
    final resetAfterSeconds = _numberFrom(window['reset_after_seconds']);
    final resetAt =
        _dateFrom(window['reset_at']) ??
        (resetAfterSeconds == null
            ? null
            : DateTime.now().add(Duration(seconds: resetAfterSeconds.round())));
    return QuotaWindow(
      label: label,
      remainingPercent: (100 - usedPercent).clamp(0.0, 100.0),
      resetAt: resetAt,
    );
  }

  Map<String, String> _headers(MonitorAccount account, String credential) =>
      account.authenticationType == AuthenticationType.manualCookie
      ? _manualCookieOrCodexOAuthHeaders(credential)
      : _apiKeyHeaders(credential);

  Map<String, String> _manualCookieOrCodexOAuthHeaders(String credential) {
    final exported = CodexOAuthCredential.tryParse(credential);
    if (exported == null) {
      return {
        'Cookie': credential,
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      };
    }
    if (exported.accountId.isEmpty) {
      throw const QuotaException('Codex 导出 JSON 缺少 chatgpt_account_id，请重新导出');
    }
    return exported.requestHeaders;
  }

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
    final kind = switch (response.statusCode) {
      401 || 403 => QuotaErrorKind.authentication,
      429 => QuotaErrorKind.rateLimit,
      >= 500 => QuotaErrorKind.server,
      _ => QuotaErrorKind.configuration,
    };
    throw QuotaException(
      'HTTP ${response.statusCode}：$detail',
      canTryNextModel: canTryNextModel,
      kind: kind,
      retryAfter: response.statusCode == 429
          ? _retryAfter(response.headers)
          : null,
    );
  }

  Duration? _retryAfter(Map<String, String> headers) {
    final raw = _header(headers, 'retry-after')?.trim();
    if (raw == null || raw.isEmpty) return null;
    final seconds = int.tryParse(raw);
    if (seconds != null) {
      return Duration(seconds: seconds.clamp(1, 24 * 60 * 60));
    }
    try {
      final remaining = HttpDate.parse(raw).difference(DateTime.now().toUtc());
      return remaining > Duration.zero ? remaining : null;
    } catch (_) {
      return null;
    }
  }

  bool _isSuccess(http.Response response) =>
      response.statusCode >= 200 && response.statusCode < 300;

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

class _NewApiBillingEndpoints {
  const _NewApiBillingEndpoints({
    required this.subscription,
    required this.usage,
  });

  final Uri subscription;
  final Uri usage;
}

class _NewApiTokenUsageResult {
  const _NewApiTokenUsageResult({required this.unlimited, this.snapshot});

  final bool unlimited;
  final QuotaSnapshot? snapshot;
}

class _NewApiDisplayConfig {
  const _NewApiDisplayConfig({
    required this.unit,
    required this.quotaPerUnit,
    required this.exchangeRate,
    required this.usesRawTokens,
  });

  factory _NewApiDisplayConfig.fromStatus(Map<String, dynamic> data) {
    final type = '${data['quota_display_type'] ?? 'USD'}'.trim().toUpperCase();
    final quotaPerUnit = _parseNumber(data['quota_per_unit']);
    return switch (type) {
      'TOKENS' => _NewApiDisplayConfig(
        unit: 'Tokens',
        quotaPerUnit: quotaPerUnit,
        exchangeRate: 1,
        usesRawTokens: true,
      ),
      'CNY' => _NewApiDisplayConfig(
        unit: 'CNY',
        quotaPerUnit: quotaPerUnit,
        exchangeRate: _parseNumber(data['usd_exchange_rate']) ?? 1,
        usesRawTokens: false,
      ),
      'CUSTOM' => _NewApiDisplayConfig(
        unit: '${data['custom_currency_symbol'] ?? ''}'.trim().isEmpty
            ? 'CUSTOM'
            : '${data['custom_currency_symbol']}'.trim(),
        quotaPerUnit: quotaPerUnit,
        exchangeRate: _parseNumber(data['custom_currency_exchange_rate']) ?? 1,
        usesRawTokens: false,
      ),
      _ => _NewApiDisplayConfig(
        unit: 'USD',
        quotaPerUnit: quotaPerUnit,
        exchangeRate: 1,
        usesRawTokens: false,
      ),
    };
  }

  final String unit;
  final double? quotaPerUnit;
  final double exchangeRate;
  final bool usesRawTokens;

  double? convertQuota(double value) {
    if (usesRawTokens) return value;
    final divisor = quotaPerUnit;
    if (divisor == null || divisor <= 0) return null;
    return value / divisor * exchangeRate;
  }

  static double? _parseNumber(dynamic value) =>
      value is num ? value.toDouble() : double.tryParse('$value');
}

enum QuotaErrorKind {
  network,
  authentication,
  rateLimit,
  configuration,
  server,
  unknown,
}

class QuotaException implements Exception {
  const QuotaException(
    this.message, {
    this.canTryNextModel = false,
    this.kind = QuotaErrorKind.unknown,
    this.retryAfter,
  });
  final String message;
  final bool canTryNextModel;
  final QuotaErrorKind kind;
  final Duration? retryAfter;
  @override
  String toString() => message;
}
