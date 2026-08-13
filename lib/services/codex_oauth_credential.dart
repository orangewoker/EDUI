import 'dart:convert';

class CodexOAuthCredential {
  const CodexOAuthCredential({
    required this.accessToken,
    required this.accountId,
    this.expiresAt,
    this.planType,
  });

  final String accessToken;
  final String accountId;
  final DateTime? expiresAt;
  final String? planType;

  String? get planLabel => switch (planType) {
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

  bool get usesWeeklyPrimary => planType == 'plus' || planType == 'pro';

  /// Drops unrelated backup data before the OAuth credential is persisted.
  String encodeForStorage() => jsonEncode({
    'type': 'edui-codex-oauth',
    'credentials': {
      'access_token': accessToken,
      'chatgpt_account_id': accountId,
      if (planType != null) 'plan_type': planType,
      if (expiresAt != null) 'expires_at': expiresAt!.toUtc().toIso8601String(),
    },
  });

  /// Returns null for a normal Cookie header. JSON-looking input is treated as
  /// an OAuth export and validated so malformed exports do not get sent as a
  /// giant Cookie header by mistake.
  static CodexOAuthCredential? tryParse(String raw) {
    final input = raw.trim().replaceFirst('\uFEFF', '');
    if (input.isEmpty) return null;
    if (!input.startsWith('{') && input.split('.').length != 3) return null;
    return CodexOAuthCredential.parse(input);
  }

  /// Accepts a Sub2API `sub2api-data` export, native Codex `auth.json`, a
  /// normalized EDUI credential, or a raw JWT.
  factory CodexOAuthCredential.parse(String raw) {
    final input = raw.trim().replaceFirst('\uFEFF', '');
    if (input.isEmpty) {
      throw const CodexOAuthCredentialException('请粘贴 Codex OAuth 导出 JSON');
    }
    if (!input.startsWith('{')) {
      if (input.split('.').length == 3) {
        return _fromSources([
          {'access_token': input},
        ]);
      }
      throw const CodexOAuthCredentialException('Codex OAuth 凭证必须是 JSON 对象');
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(input);
    } catch (_) {
      throw const CodexOAuthCredentialException('无法解析 Codex OAuth 导出 JSON');
    }
    if (decoded is! Map) {
      throw const CodexOAuthCredentialException('Codex OAuth 凭证必须是 JSON 对象');
    }
    final root = Map<String, dynamic>.from(decoded);
    final accounts = root['accounts'];
    if (accounts is List) {
      CodexOAuthCredentialException? lastError;
      for (final accountValue in accounts.whereType<Map>()) {
        final account = Map<String, dynamic>.from(accountValue);
        final platform = '${account['platform'] ?? ''}'.toLowerCase();
        final type = '${account['type'] ?? ''}'.toLowerCase();
        if (platform.isNotEmpty && platform != 'openai') continue;
        if (type.isNotEmpty && type != 'oauth') continue;
        final credentials = account['credentials'] is Map
            ? Map<String, dynamic>.from(account['credentials'] as Map)
            : const <String, dynamic>{};
        try {
          return _fromSources([credentials, account, root]);
        } on CodexOAuthCredentialException catch (error) {
          lastError = error;
        }
      }
      if (lastError != null) throw lastError;
      throw const CodexOAuthCredentialException(
        '导出 JSON 中没有可用的 OpenAI OAuth 账户',
      );
    }

    final tokens = root['tokens'] is Map
        ? Map<String, dynamic>.from(root['tokens'] as Map)
        : const <String, dynamic>{};
    final credentials = root['credentials'] is Map
        ? Map<String, dynamic>.from(root['credentials'] as Map)
        : const <String, dynamic>{};
    return _fromSources([tokens, credentials, root]);
  }

  Map<String, String> get requestHeaders => {
    'Authorization': 'Bearer $accessToken',
    if (accountId.isNotEmpty) 'ChatGPT-Account-Id': accountId,
    'Accept': 'application/json',
    'User-Agent': 'codex-cli',
  };

  static CodexOAuthCredential _fromSources(List<Map<String, dynamic>> sources) {
    var token = _firstString(sources, const ['access_token', 'accessToken']);
    if (token.toLowerCase().startsWith('bearer ')) {
      token = token.substring(7).trim();
    }
    if (token.isEmpty) {
      throw const CodexOAuthCredentialException('导出 JSON 缺少 access_token');
    }

    final claims = _jwtClaims(token);
    var accountId = _firstString(sources, const [
      'chatgpt_account_id',
      'chatgptAccountId',
      'account_id',
      'accountId',
    ]);
    if (accountId.isNotEmpty && accountId.startsWith('org-')) {
      accountId = '';
    }
    if (accountId.isEmpty) {
      accountId = _firstString(
        [claims],
        const [
          'https://api.openai.com/auth.chatgpt_account_id',
          'chatgpt_account_id',
        ],
      );
    }
    if (accountId.isEmpty && claims['https://api.openai.com/auth'] is Map) {
      accountId = _firstString(
        [
          Map<String, dynamic>.from(
            claims['https://api.openai.com/auth'] as Map,
          ),
        ],
        const ['chatgpt_account_id'],
      );
    }
    if (accountId.isEmpty) {
      throw const CodexOAuthCredentialException(
        '导出 JSON 缺少 chatgpt_account_id',
      );
    }
    final expiryValue = _firstValue(sources, const [
      'expires_at',
      'expiresAt',
      'expires',
    ]);
    final expiresAt = _parseDate(expiryValue ?? claims['exp']);
    if (expiresAt != null && !expiresAt.isAfter(DateTime.now())) {
      throw const CodexOAuthCredentialException('Codex OAuth 凭证已过期，请重新导出后粘贴');
    }
    final planType =
        normalizePlanType(
          _firstString(sources, const [
            'plan_type',
            'planType',
            'chatgpt_plan_type',
            'chatgptPlanType',
            'subscription_plan',
          ]),
        ) ??
        _planTypeFromClaims(claims);
    return CodexOAuthCredential(
      accessToken: token,
      accountId: accountId,
      expiresAt: expiresAt,
      planType: planType,
    );
  }

  static String? normalizePlanType(dynamic value) {
    final raw = '${value ?? ''}'.trim().toLowerCase();
    if (raw.isEmpty) return null;
    final compact = raw.replaceAll(RegExp(r'[^a-z0-9]+'), '');
    return switch (compact) {
      'chatgptplus' || 'plus' => 'plus',
      'chatgptpro' || 'pro' => 'pro',
      'k12' || 'chatgptk12' => 'k12',
      'free' || 'chatgptfree' => 'free',
      'team' || 'chatgptteam' => 'team',
      'business' || 'chatgptbusiness' => 'business',
      'enterprise' || 'chatgptenterprise' => 'enterprise',
      'edu' || 'education' || 'chatgptedu' => 'edu',
      _ => raw,
    };
  }

  static String? _planTypeFromClaims(Map<String, dynamic> claims) {
    final direct = normalizePlanType(
      _firstString(
        [claims],
        const ['plan_type', 'chatgpt_plan_type', 'subscription_plan'],
      ),
    );
    if (direct != null) return direct;
    for (final key in const [
      'https://api.openai.com/auth',
      'https://api.openai.com/profile',
    ]) {
      final nested = claims[key];
      if (nested is! Map) continue;
      final plan = normalizePlanType(
        _firstString(
          [Map<String, dynamic>.from(nested)],
          const ['plan_type', 'chatgpt_plan_type', 'subscription_plan'],
        ),
      );
      if (plan != null) return plan;
    }
    return null;
  }

  static String _firstString(
    List<Map<String, dynamic>> sources,
    List<String> keys,
  ) {
    final value = _firstValue(sources, keys);
    return value is String ? value.trim() : '${value ?? ''}'.trim();
  }

  static dynamic _firstValue(
    List<Map<String, dynamic>> sources,
    List<String> keys,
  ) {
    for (final source in sources) {
      for (final key in keys) {
        final value = source[key];
        if (value != null && '$value'.trim().isNotEmpty) return value;
      }
    }
    return null;
  }

  static Map<String, dynamic> _jwtClaims(String token) {
    final parts = token.split('.');
    if (parts.length < 2) return const {};
    try {
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final decoded = jsonDecode(payload);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
    } catch (_) {
      return const {};
    }
  }

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    if (value is num) {
      final raw = value.toInt();
      return DateTime.fromMillisecondsSinceEpoch(
        raw.abs() >= 100000000000 ? raw : raw * 1000,
        isUtc: true,
      );
    }
    final text = '$value'.trim();
    final numeric = int.tryParse(text);
    if (numeric != null) return _parseDate(numeric);
    return DateTime.tryParse(text)?.toUtc();
  }
}

class CodexOAuthCredentialException implements Exception {
  const CodexOAuthCredentialException(this.message);

  final String message;

  @override
  String toString() => message;
}
