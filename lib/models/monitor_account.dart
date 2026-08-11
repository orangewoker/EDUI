import 'dart:convert';

enum ProviderType {
  amdRadeon,
  deepSeek,
  customJson;

  String get label => switch (this) {
    ProviderType.amdRadeon => 'OpenAI 兼容额度',
    ProviderType.deepSeek => 'DeepSeek 余额',
    ProviderType.customJson => '自定义 JSON',
  };
}

class MonitorAccount {
  const MonitorAccount({
    required this.id,
    required this.name,
    required this.providerType,
    required this.baseUrl,
    this.model = '',
    this.endpointPath = '',
    this.balanceField = '',
    this.limitField = '',
    this.unit = 'USD',
    this.enabled = true,
  });

  final String id;
  final String name;
  final ProviderType providerType;
  final String baseUrl;
  final String model;
  final String endpointPath;
  final String balanceField;
  final String limitField;
  final String unit;
  final bool enabled;

  factory MonitorAccount.amdDefault() => MonitorAccount(
    id: 'amd-radeon',
    name: 'AMD Radeon API',
    providerType: ProviderType.amdRadeon,
    baseUrl: 'https://developer.amd.com.cn/radeon/api/v1',
    model: '',
  );

  MonitorAccount copyWith({
    String? name,
    ProviderType? providerType,
    String? baseUrl,
    String? model,
    String? endpointPath,
    String? balanceField,
    String? limitField,
    String? unit,
    bool? enabled,
  }) {
    return MonitorAccount(
      id: id,
      name: name ?? this.name,
      providerType: providerType ?? this.providerType,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      endpointPath: endpointPath ?? this.endpointPath,
      balanceField: balanceField ?? this.balanceField,
      limitField: limitField ?? this.limitField,
      unit: unit ?? this.unit,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'providerType': providerType.name,
    'baseUrl': baseUrl,
    'model': model,
    'endpointPath': endpointPath,
    'balanceField': balanceField,
    'limitField': limitField,
    'unit': unit,
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
    model: '${json['model'] ?? ''}',
    endpointPath: '${json['endpointPath'] ?? ''}',
    balanceField: '${json['balanceField'] ?? ''}',
    limitField: '${json['limitField'] ?? ''}',
    unit: '${json['unit'] ?? 'USD'}',
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
