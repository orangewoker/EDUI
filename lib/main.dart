import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'models/monitor_account.dart';
import 'models/quota_snapshot.dart';
import 'services/login_launcher.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EDUIApp());
}

class EDUIApp extends StatefulWidget {
  const EDUIApp({super.key});

  @override
  State<EDUIApp> createState() => _EDUIAppState();
}

class _EDUIAppState extends State<EDUIApp> {
  final controller = AppController();

  @override
  void initState() {
    super.initState();
    controller.initialize();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF5B67F1);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'EDUI',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F6FB),
        cardTheme: const CardThemeData(
          elevation: 0,
          color: Colors.white,
          margin: EdgeInsets.zero,
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0E1018),
        cardTheme: const CardThemeData(
          elevation: 0,
          color: Color(0xFF191C27),
          margin: EdgeInsets.zero,
        ),
      ),
      home: DashboardPage(controller: controller),
    );
  }
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (controller.loading) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return Scaffold(
          body: RefreshIndicator(
            onRefresh: controller.refreshAll,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverAppBar.large(
                  title: const Text('EDUI'),
                  actions: [
                    IconButton(
                      tooltip: '全部刷新',
                      onPressed: controller.refreshing.isEmpty
                          ? controller.refreshAll
                          : null,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                  sliver: SliverList.list(
                    children: [
                      _SummaryPanel(controller: controller),
                      const SizedBox(height: 22),
                      Row(
                        children: [
                          Text(
                            '监控账户',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const Spacer(),
                          FilledButton.tonalIcon(
                            onPressed: () =>
                                _openEditor(context, controller, null),
                            icon: const Icon(Icons.add_rounded),
                            label: const Text('添加'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (controller.accounts.isEmpty)
                        const _EmptyState()
                      else
                        for (final account in controller.accounts) ...[
                          _AccountCard(
                            account: account,
                            snapshot: controller.snapshotFor(account.id),
                            error: controller.errors[account.id],
                            refreshing: controller.refreshing.contains(
                              account.id,
                            ),
                            onRefresh: () => controller.refreshOne(account),
                            onLogin:
                                account.appUrl.isEmpty &&
                                    account.loginUrl.isEmpty
                                ? null
                                : () => _openLogin(context, account),
                            onEdit: () =>
                                _openEditor(context, controller, account),
                          ),
                          const SizedBox(height: 12),
                        ],
                      const SizedBox(height: 10),
                      const _WidgetHelp(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openLogin(BuildContext context, MonitorAccount account) async {
    final opened = await const LoginLauncher().open(account);
    if (!context.mounted || opened) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法打开官方 App 或登录网页')));
  }

  Future<void> _openEditor(
    BuildContext context,
    AppController controller,
    MonitorAccount? account,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) =>
          AccountEditor(controller: controller, initial: account),
    );
  }
}

class _SummaryPanel extends StatelessWidget {
  const _SummaryPanel({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final available = controller.snapshots.length;
    final problems = controller.errors.length;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF5763EE), Color(0xFF8A5CF5)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x335763EE),
            blurRadius: 24,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.monitor_heart_rounded, color: Colors.white),
              SizedBox(width: 8),
              Text('模型额度总览', style: TextStyle(color: Colors.white70)),
            ],
          ),
          const SizedBox(height: 26),
          Text(
            '$available 个账户已同步',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 25,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            problems == 0 ? '所有已配置服务运行正常' : '$problems 个服务需要处理',
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.account,
    required this.snapshot,
    required this.error,
    required this.refreshing,
    required this.onRefresh,
    required this.onLogin,
    required this.onEdit,
  });
  final MonitorAccount account;
  final QuotaSnapshot? snapshot;
  final String? error;
  final bool refreshing;
  final VoidCallback onRefresh;
  final VoidCallback? onLogin;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final ratio = snapshot?.remainingRatio;
    final color = error == null ? const Color(0xFF5B67F1) : Colors.redAccent;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(Icons.bolt_rounded, color: color),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          account.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 17,
                          ),
                        ),
                        Text(
                          account.providerType.label,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (onLogin != null)
                    IconButton(
                      tooltip: '打开官方登录',
                      onPressed: onLogin,
                      icon: const Icon(Icons.login_rounded),
                    ),
                  IconButton(
                    tooltip: '刷新',
                    onPressed: refreshing ? null : onRefresh,
                    icon: refreshing
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                )
              else if (snapshot == null)
                const Text('尚未同步，点击刷新开始测试')
              else ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _formatNumber(snapshot!.remaining),
                      style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Text(snapshot!.unit),
                    ),
                    const Spacer(),
                    if (snapshot!.requestRemaining != null)
                      Text(
                        '${snapshot!.requestRemaining}/${snapshot!.requestLimit} RPM',
                      ),
                  ],
                ),
                if (ratio != null) ...[
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(
                      value: ratio,
                      minHeight: 7,
                      backgroundColor: color.withValues(alpha: .12),
                      color: color,
                    ),
                  ),
                ],
                const SizedBox(height: 11),
                Text(
                  '更新于 ${_formatTime(snapshot!.updatedAt)}${snapshot!.resetAt == null ? '' : ' · ${_formatTime(snapshot!.resetAt!)} 重置'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _formatNumber(double value) {
    if (value.abs() >= 100) return value.toStringAsFixed(0);
    if (value.abs() >= 1) return value.toStringAsFixed(2);
    return value.toStringAsFixed(4);
  }

  String _formatTime(DateTime value) {
    final local = value.toLocal();
    return '${local.month}/${local.day} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}

class AccountEditor extends StatefulWidget {
  const AccountEditor({super.key, required this.controller, this.initial});
  final AppController controller;
  final MonitorAccount? initial;

  @override
  State<AccountEditor> createState() => _AccountEditorState();
}

class _AccountEditorState extends State<AccountEditor> {
  late ProviderType type;
  late AuthenticationType authenticationType;
  late MetricValueMode metricValueMode;
  late final TextEditingController name;
  late final TextEditingController baseUrl;
  late final TextEditingController model;
  late final TextEditingController endpoint;
  late final TextEditingController balanceField;
  late final TextEditingController limitField;
  late final TextEditingController resetField;
  late final TextEditingController unit;
  late final TextEditingController budgetLimit;
  late final TextEditingController appUrl;
  late final TextEditingController loginUrl;
  final credential = TextEditingController();
  bool saving = false;
  bool hasStoredKey = false;

  @override
  void initState() {
    super.initState();
    final value = widget.initial ?? MonitorAccount.amdDefault();
    type = value.providerType;
    authenticationType = value.authenticationType;
    metricValueMode = value.metricValueMode;
    name = TextEditingController(
      text: widget.initial?.name ?? 'AMD Radeon API',
    );
    baseUrl = TextEditingController(text: value.baseUrl);
    model = TextEditingController(text: value.model);
    endpoint = TextEditingController(text: value.endpointPath);
    balanceField = TextEditingController(text: value.balanceField);
    limitField = TextEditingController(text: value.limitField);
    resetField = TextEditingController(text: value.resetField);
    unit = TextEditingController(text: value.unit);
    budgetLimit = TextEditingController(
      text: value.budgetLimit == null ? '' : '${value.budgetLimit}',
    );
    appUrl = TextEditingController(text: value.appUrl);
    loginUrl = TextEditingController(text: value.loginUrl);
    if (widget.initial != null) {
      widget.controller.hasCredential(widget.initial!).then((value) {
        if (mounted) setState(() => hasStoredKey = value);
      });
    }
  }

  @override
  void dispose() {
    for (final item in [
      name,
      baseUrl,
      model,
      endpoint,
      balanceField,
      limitField,
      resetField,
      unit,
      budgetLimit,
      appUrl,
      loginUrl,
      credential,
    ]) {
      item.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final custom = type == ProviderType.customJson;
    final openAI = type == ProviderType.amdRadeon;
    final officialOpenAI = type == ProviderType.openAI;
    final cookie = authenticationType == AuthenticationType.manualCookie;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.initial == null ? '添加监控' : '编辑监控'),
        actions: [
          TextButton(onPressed: saving ? null : _save, child: const Text('保存')),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          18,
          8,
          18,
          math.max(MediaQuery.paddingOf(context).bottom, 24),
        ),
        children: [
          Text(
            '快速配置',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: () => _applyPreset(
                  MonitorAccount.openAIDefault(id: 'editor-preview'),
                ),
                icon: const Icon(Icons.auto_awesome_rounded),
                label: const Text('OpenAI API'),
              ),
              OutlinedButton.icon(
                onPressed: () => _applyPreset(
                  MonitorAccount.codexDefault(id: 'editor-preview'),
                ),
                icon: const Icon(Icons.code_rounded),
                label: const Text('Codex 订阅'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<ProviderType>(
            key: ValueKey(type),
            initialValue: type,
            decoration: const InputDecoration(
              labelText: '服务类型',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final value in ProviderType.values)
                DropdownMenuItem(value: value, child: Text(value.label)),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() {
                type = value;
                if (value != ProviderType.customJson) {
                  authenticationType = AuthenticationType.apiKey;
                }
                if (value == ProviderType.deepSeek) {
                  baseUrl.text = 'https://api.deepseek.com';
                  name.text = 'DeepSeek';
                  appUrl.text = 'https://chat.deepseek.com/';
                  loginUrl.text = 'https://platform.deepseek.com/';
                } else if (value == ProviderType.openAI) {
                  _setFields(
                    MonitorAccount.openAIDefault(id: 'editor-preview'),
                  );
                }
              });
            },
          ),
          const SizedBox(height: 14),
          if (custom) ...[
            DropdownButtonFormField<AuthenticationType>(
              key: ValueKey(authenticationType),
              initialValue: authenticationType,
              decoration: const InputDecoration(
                labelText: '登录凭证',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final value in AuthenticationType.values)
                  DropdownMenuItem(value: value, child: Text(value.label)),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    authenticationType = value;
                    hasStoredKey = false;
                  });
                }
              },
            ),
            const SizedBox(height: 14),
          ],
          _field(name, '显示名称'),
          _field(baseUrl, 'API Base URL', keyboard: TextInputType.url),
          if (openAI)
            const Padding(
              padding: EdgeInsets.only(bottom: 14),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.auto_awesome_rounded),
                title: Text('自动选择可用模型'),
                subtitle: Text('EDUI 会读取 /models，并自动尝试可用模型，无需手动填写。'),
              ),
            ),
          if (officialOpenAI)
            _field(
              budgetLimit,
              '月预算上限（可选）',
              helper: '填写后显示预算余额和进度；留空则显示最近 30 天已用',
              keyboard: const TextInputType.numberWithOptions(decimal: true),
            ),
          if (custom) ...[
            _field(endpoint, '接口路径', helper: '例如 /api/user/self'),
            _field(balanceField, '剩余额度字段', helper: '支持 data.quota 这类点号路径'),
            _field(limitField, '总额度字段（可选）'),
            DropdownButtonFormField<MetricValueMode>(
              key: ValueKey(metricValueMode),
              initialValue: metricValueMode,
              decoration: const InputDecoration(
                labelText: '额度字段含义',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final value in MetricValueMode.values)
                  DropdownMenuItem(value: value, child: Text(value.label)),
              ],
              onChanged: (value) {
                if (value != null) setState(() => metricValueMode = value);
              },
            ),
            const SizedBox(height: 14),
            _field(
              resetField,
              '重置时间字段（可选）',
              helper: '支持 Unix 秒、Unix 毫秒或 ISO 8601 时间',
            ),
            _field(unit, '单位'),
          ],
          if (custom || appUrl.text.isNotEmpty || loginUrl.text.isNotEmpty) ...[
            _field(
              appUrl,
              '官方 App Link（可选）',
              helper: '优先尝试 Universal Link 或官方 App URL Scheme',
              keyboard: TextInputType.url,
            ),
            _field(
              loginUrl,
              '网页登录地址（可选）',
              helper: '未安装官方 App 时自动回退到这里',
              keyboard: TextInputType.url,
            ),
            OutlinedButton.icon(
              onPressed: _openOfficialLogin,
              icon: const Icon(Icons.open_in_new_rounded),
              label: const Text('打开官方 App / 网页登录'),
            ),
            const SizedBox(height: 14),
          ],
          if (cookie)
            const Padding(
              padding: EdgeInsets.only(bottom: 14),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.info_outline_rounded),
                title: Text('网页登录不会把 Cookie 自动交给 EDUI'),
                subtitle: Text(
                  '请从你自己的已登录浏览器复制完整 Cookie；Cookie 只保存到 iOS Keychain。Codex 模板使用实验性额度接口，失效时可直接修改接口和字段。',
                ),
              ),
            ),
          TextField(
            controller: credential,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: cookie ? 'Cookie' : 'API Key',
              helperText: hasStoredKey
                  ? '已安全保存；留空表示不修改'
                  : cookie
                  ? '粘贴完整 Cookie Header，保存在 iOS Keychain'
                  : type == ProviderType.openAI
                  ? 'OpenAI Costs API 需要组织 Admin API Key'
                  : '保存在 iOS Keychain，不写入小组件数据',
              border: const OutlineInputBorder(),
              prefixIcon: Icon(
                cookie ? Icons.cookie_outlined : Icons.key_rounded,
              ),
            ),
          ),
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: saving ? null : _save,
            icon: saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded),
            label: const Text('保存配置'),
          ),
          if (widget.initial != null) ...[
            const SizedBox(height: 12),
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: saving ? null : _delete,
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('删除这个监控'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? helper,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      controller: controller,
      keyboardType: keyboard,
      autocorrect: false,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  void _setFields(MonitorAccount value) {
    type = value.providerType;
    authenticationType = value.authenticationType;
    name.text = value.name;
    baseUrl.text = value.baseUrl;
    model.text = value.model;
    endpoint.text = value.endpointPath;
    balanceField.text = value.balanceField;
    limitField.text = value.limitField;
    resetField.text = value.resetField;
    metricValueMode = value.metricValueMode;
    unit.text = value.unit;
    budgetLimit.text = value.budgetLimit == null ? '' : '${value.budgetLimit}';
    appUrl.text = value.appUrl;
    loginUrl.text = value.loginUrl;
  }

  void _applyPreset(MonitorAccount value) {
    setState(() {
      _setFields(value);
      hasStoredKey = false;
    });
  }

  MonitorAccount _draftAccount(String id) => MonitorAccount(
    id: id,
    name: name.text.trim(),
    providerType: type,
    baseUrl: baseUrl.text.trim(),
    authenticationType: authenticationType,
    model: type == ProviderType.amdRadeon ? '' : model.text.trim(),
    endpointPath: endpoint.text.trim(),
    balanceField: balanceField.text.trim(),
    limitField: limitField.text.trim(),
    resetField: resetField.text.trim(),
    metricValueMode: metricValueMode,
    unit: unit.text.trim().isEmpty ? 'USD' : unit.text.trim(),
    budgetLimit: double.tryParse(budgetLimit.text.trim()),
    appUrl: appUrl.text.trim(),
    loginUrl: loginUrl.text.trim(),
  );

  Future<void> _openOfficialLogin() async {
    final opened = await const LoginLauncher().open(
      _draftAccount(widget.initial?.id ?? 'editor-preview'),
    );
    if (!mounted || opened) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法打开官方 App 或登录网页')));
  }

  Future<void> _save() async {
    if (name.text.trim().isEmpty || baseUrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('名称和 URL 不能为空')));
      return;
    }
    setState(() => saving = true);
    final id =
        widget.initial?.id ??
        'account-${DateTime.now().millisecondsSinceEpoch}';
    final account = _draftAccount(id);
    await widget.controller.saveAccount(account, credential.text);
    final canRefresh = await widget.controller.hasCredential(account);
    if (!mounted) return;
    Navigator.pop(context);
    if (canRefresh) {
      await widget.controller.refreshOne(account);
    }
  }

  Future<void> _delete() async {
    setState(() => saving = true);
    await widget.controller.removeAccount(widget.initial!.id);
    if (mounted) Navigator.pop(context);
  }
}

class _WidgetHelp extends StatelessWidget {
  const _WidgetHelp();
  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: const Padding(
        padding: EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.widgets_rounded),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                '长按 iPhone 桌面 → 编辑 → 添加小组件 → 搜索 EDUI。添加后长按小组件并选择“编辑小组件”，即可选择账户和“液态玻璃 / 白色”外观。',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 50),
    child: Center(child: Text('还没有监控账户')),
  );
}
