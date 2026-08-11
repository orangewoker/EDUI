import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'models/monitor_account.dart';
import 'models/quota_snapshot.dart';

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
    required this.onEdit,
  });
  final MonitorAccount account;
  final QuotaSnapshot? snapshot;
  final String? error;
  final bool refreshing;
  final VoidCallback onRefresh;
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
  late final TextEditingController name;
  late final TextEditingController baseUrl;
  late final TextEditingController model;
  late final TextEditingController endpoint;
  late final TextEditingController balanceField;
  late final TextEditingController limitField;
  late final TextEditingController unit;
  final apiKey = TextEditingController();
  bool saving = false;
  bool hasStoredKey = false;

  @override
  void initState() {
    super.initState();
    final value = widget.initial ?? MonitorAccount.amdDefault();
    type = value.providerType;
    name = TextEditingController(
      text: widget.initial?.name ?? 'AMD Radeon API',
    );
    baseUrl = TextEditingController(text: value.baseUrl);
    model = TextEditingController(text: value.model);
    endpoint = TextEditingController(text: value.endpointPath);
    balanceField = TextEditingController(text: value.balanceField);
    limitField = TextEditingController(text: value.limitField);
    unit = TextEditingController(text: value.unit);
    if (widget.initial != null) {
      widget.controller.hasApiKey(widget.initial!.id).then((value) {
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
      unit,
      apiKey,
    ]) {
      item.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final custom = type == ProviderType.customJson;
    final openAI = type == ProviderType.amdRadeon;
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
          DropdownButtonFormField<ProviderType>(
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
                if (value == ProviderType.deepSeek) {
                  baseUrl.text = 'https://api.deepseek.com';
                  name.text = 'DeepSeek';
                }
              });
            },
          ),
          const SizedBox(height: 14),
          _field(name, '显示名称'),
          _field(baseUrl, 'API Base URL', keyboard: TextInputType.url),
          if (openAI) _field(model, '探测模型', helper: '每次刷新发送 1 token 的最小请求'),
          if (custom) ...[
            _field(endpoint, '接口路径', helper: '例如 /api/user/self'),
            _field(balanceField, '剩余额度字段', helper: '支持 data.quota 这类点号路径'),
            _field(limitField, '总额度字段（可选）'),
            _field(unit, '单位'),
          ],
          TextField(
            controller: apiKey,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'API Key',
              helperText: hasStoredKey
                  ? '已安全保存；留空表示不修改'
                  : '保存在 iOS Keychain，不写入小组件数据',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.key_rounded),
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
    final account = MonitorAccount(
      id: id,
      name: name.text.trim(),
      providerType: type,
      baseUrl: baseUrl.text.trim(),
      model: model.text.trim(),
      endpointPath: endpoint.text.trim(),
      balanceField: balanceField.text.trim(),
      limitField: limitField.text.trim(),
      unit: unit.text.trim().isEmpty ? 'USD' : unit.text.trim(),
    );
    await widget.controller.saveAccount(account, apiKey.text);
    if (!mounted) return;
    Navigator.pop(context);
    if (apiKey.text.trim().isNotEmpty || hasStoredKey) {
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
                '长按 iPhone 桌面 → 编辑 → 添加小组件 → 搜索 EDUI。添加后长按 EDUI 小组件并选择“编辑小组件”，填写 API Key。',
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
