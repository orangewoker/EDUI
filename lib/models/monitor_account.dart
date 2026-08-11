import 'dart:convert';

enum ProviderType {
  openAI,
  amdRadeon,
  deepSeek,
  customJson;

  String get label => switch (this) {
    ProviderType.openAI => 'OpenAI API 用量',
    ProviderType.amdRadeon => 'OpenAI 兼容额度（自动识别）',
    ProviderType.deepSeek => 'DeepSeek 余额',
    ProviderType.customJson => '官方账户 / 自定义 JSON',
  };
}

enum AuthenticationType {
  apiKey,
  manualCookie;

  String get label => switch (this) {
    AuthenticationType.apiKey => 'API Key',
    AuthenticationType.manualCookie => '网页登录 / 手动 Cookie',
  };
}

enum MetricValueMode {
  remaining,
  used,
  usedPercent;

  String get label => switch (this) {
    MetricValueMode.remaining => '接口值就是剩余额度',
    MetricValueMode.used => '接口值是已用额度',
    MetricValueMode.usedPercent => '接口值是已用百分比',
  };
}

class MonitorAccount {
  const MonitorAccount({
    required this.id,
    required this.name,
    required this.providerType,
    required this.baseUrl,
    this.authenticationType = AuthenticationType.apiKey,
    this.model = '',
    this.endpointPath = '',
    this.balanceField = '',
    this.limitField = '',
    this.resetField = '',
    this.metricValueMode = MetricValueMode.remaining,
    this.unit = 'USD',
    this.budgetLimit,
    this.appUrl = '',
    this.loginUrl = '',
    this.enabled = true,
  });

  final String id;
  final String name;
  final ProviderType providerType;
  final String baseUrl;
  final AuthenticationType authenticationType;
  final String model;
  final String endpointPath;
  final String balanceField;
  final String limitField;
  final String resetField;
  final MetricValueMode metricValueMode;
  final String unit;
  final double? budgetLimit;
  final String appUrl;
  final String loginUrl;
  final bool enabled;

  factory MonitorAccount.amdDefault() => MonitorAccount(
    id: 'amd-radeon',
    name: 'AMD Radeon API',
    providerType: ProviderType.amdRadeon,
    baseUrl: 'https://developer.amd.com.cn/radeon/api/v1',
    model: '',
  );

  factory MonitorAccount.openAIDefault({
    String id = 'openai-platform',
  }) => MonitorAccount(
    id: id,
    name: 'OpenAI API',
    providerType: ProviderType.openAI,
    baseUrl: 'https://api.openai.com/v1',
    unit: 'USD/30天已用',
    appUrl: 'https://chatgpt.com/',
    loginUrl:
        'https://platform.openai.com/settings/organization/billing/overview',
  );

  factory MonitorAccount.codexDefault({required String id}) => MonitorAccount(
    id: id,
    name: 'Codex / ChatGPT 订阅',
    providerType: ProviderType.customJson,
    baseUrl: 'https://chatgpt.com',
    authenticationType: AuthenticationType.manualCookie,
    endpointPath: '/backend-api/wham/usage',
    balanceField: 'rate_limit.primary_window.used_percent',
    resetField: 'rate_limit.primary_window.reset_at',
    metricValueMode: MetricValueMode.usedPercent,
    unit: '%',
    appUrl: 'https://chatgpt.com/',
    loginUrl: 'https://chatgpt.com/auth/login',
  );

  MonitorAccount copyWith({
    String? name,
    ProviderType? providerType,
    String? baseUrl,
    AuthenticationType? authenticationType,
    String? model,
    String? endpointPath,
    String? balanceField,
    String? limitField,
    String? resetField,
    MetricValueMode? metricValueMode,
    String? unit,
    double? budgetLimit,
    bool clearBudgetLimit = false,
    String? appUrl,
    String? loginUrl,
    bool? enabled,
  }) {
    return MonitorAccount(
      id: id,
      name: name ?? this.name,
      providerType: providerType ?? this.providerType,
      baseUrl: baseUrl ?? this.baseUrl,
      authenticationType: authenticationType ?? this.authenticationType,
      model: model ?? this.model,
      endpointPath: endpointPath ?? this.endpointPath,
      balanceField: balanceField ?? this.balanceField,
      limitField: limitField ?? this.limitField,
      resetField: resetField ?? this.resetField,
      metricValueMode: metricValueMode ?? this.metricValueMode,
      unit: unit ?? this.unit,
      budgetLimit: clearBudgetLimit ? null : budgetLimit ?? this.budgetLimit,
      appUrl: appUrl ?? this.appUrl,
      loginUrl: loginUrl ?? this.loginUrl,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'providerType': providerType.name,
    'baseUrl': baseUrl,
    'authenticationType': authenticationType.name,
    'model': model,
    'endpointPath': endpointPath,
    'balanceField': balanceField,
    'limitField': limitField,
    'resetField': resetField,
    'metricValueMode': metricValueMode.name,
    'unit': unit,
    'budgetLimit': budgetLimit,
    'appUrl': appUrl,
    'loginUrl': loginUrl,
    'enabled': enabled,
  };

  factory MonitorAccount.fromJson(Map<String, dynamic> json) => MonitorAccount(
    id: '${json['id']}',
    name: '${json['name'] ?? '未命名服务'}',
    providerType: ProviderType.values.firstWhere(
      (value) => value.name == json['providerType'],
      orElse: () => ProviderType.customJson,
    ),
    baseUrl: '${json['baseUrl'] ?? ''}',
    authenticationType: AuthenticationType.values.firstWhere(
      (value) => value.name == json['authenticationType'],
      orElse: () => AuthenticationType.apiKey,
    ),
    model: '${json['model'] ?? ''}',
    endpointPath: '${json['endpointPath'] ?? ''}',
    balanceField: '${json['balanceField'] ?? ''}',
    limitField: '${json['limitField'] ?? ''}',
    resetField: '${json['resetField'] ?? ''}',
    metricValueMode: MetricValueMode.values.firstWhere(
      (value) => value.name == json['metricValueMode'],
      orElse: () => MetricValueMode.remaining,
    ),
    unit: '${json['unit'] ?? 'USD'}',
    budgetLimit: json['budgetLimit'] is num
        ? (json['budgetLimit'] as num).toDouble()
        : double.tryParse('${json['budgetLimit'] ?? ''}'),
    appUrl: '${json['appUrl'] ?? ''}',
    loginUrl: '${json['loginUrl'] ?? ''}',
    enabled: json['enabled'] != false,
  );

  static String encodeList(List<MonitorAccount> values) =>
      jsonEncode(values.map((item) => item.toJson()).toList());

  static List<MonitorAccount> decodeList(String raw) =>
      (jsonDecode(raw) as List)
          .whereType<Map>()
          .map(
            (item) => MonitorAccount.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList();
}
