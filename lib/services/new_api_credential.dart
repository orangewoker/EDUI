import 'dart:convert';

/// Credentials used by a New API / One API relay.
///
/// A relay API key can query models and key-scoped quota. Sites whose keys are
/// marked unlimited need a separate dashboard access token/PAT to expose the
/// owning user's wallet through `/api/user/self`.
class NewApiCredential {
  const NewApiCredential({required this.apiKey, this.dashboardToken = ''});

  final String apiKey;
  final String dashboardToken;

  bool get hasDashboardToken => dashboardToken.isNotEmpty;

  factory NewApiCredential.parse(String raw) {
    final input = raw.trim();
    if (!input.startsWith('{')) {
      return NewApiCredential(apiKey: _stripBearer(input));
    }
    try {
      final decoded = jsonDecode(input);
      if (decoded is! Map) return NewApiCredential(apiKey: input);
      final root = Map<String, dynamic>.from(decoded);
      final apiKey = _firstString(root, const [
        'api_key',
        'apiKey',
        'relay_api_key',
      ]);
      final dashboardToken = _firstString(root, const [
        'dashboard_access_token',
        'dashboardToken',
        'access_token',
        'accessToken',
        'pat',
      ]);
      if (apiKey.isEmpty && dashboardToken.isEmpty) {
        return NewApiCredential(apiKey: input);
      }
      return NewApiCredential(
        apiKey: _stripBearer(apiKey),
        dashboardToken: _stripBearer(dashboardToken),
      );
    } catch (_) {
      return NewApiCredential(apiKey: input);
    }
  }

  static String merge(
    String existing, {
    String apiKey = '',
    String dashboardToken = '',
  }) {
    final current = NewApiCredential.parse(existing);
    final merged = NewApiCredential(
      apiKey: apiKey.trim().isEmpty
          ? current.apiKey
          : _stripBearer(apiKey.trim()),
      dashboardToken: dashboardToken.trim().isEmpty
          ? current.dashboardToken
          : _dashboardTokenFromInput(dashboardToken),
    );
    return merged.encodeForStorage();
  }

  String encodeForStorage() {
    if (dashboardToken.isEmpty) return apiKey;
    return jsonEncode({
      'type': 'edui-new-api-credential',
      'version': 1,
      'api_key': apiKey,
      'dashboard_access_token': dashboardToken,
    });
  }

  static String _dashboardTokenFromInput(String raw) {
    final input = raw.trim();
    if (!input.startsWith('{')) return _stripBearer(input);
    try {
      final decoded = jsonDecode(input);
      final found = _findToken(decoded);
      return _stripBearer(found.isEmpty ? input : found);
    } catch (_) {
      return _stripBearer(input);
    }
  }

  static String _findToken(dynamic value) {
    if (value is Map) {
      for (final key in const [
        'dashboard_access_token',
        'access_token',
        'accessToken',
        'pat',
      ]) {
        final candidate = value[key];
        if (candidate is String && candidate.trim().isNotEmpty) {
          return candidate.trim();
        }
      }
      for (final child in value.values) {
        final found = _findToken(child);
        if (found.isNotEmpty) return found;
      }
    } else if (value is List) {
      for (final child in value) {
        final found = _findToken(child);
        if (found.isNotEmpty) return found;
      }
    }
    return '';
  }

  static String _firstString(Map<String, dynamic> value, List<String> keys) {
    for (final key in keys) {
      final candidate = value[key];
      if (candidate is String && candidate.trim().isNotEmpty) {
        return candidate.trim();
      }
    }
    return '';
  }

  static String _stripBearer(String value) {
    final input = value.trim();
    return input.toLowerCase().startsWith('bearer ')
        ? input.substring(7).trim()
        : input;
  }
}
