import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../giwifi/giwifi_client.dart';
import '../giwifi/giwifi_models.dart';
import 'app_settings.dart';

enum _ConnectionViewState { disconnected, connecting, connected, failed }

enum _AppMenuAction { theme, portal, about }

const Duration _cardFlowDuration = Duration(milliseconds: 280);

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.settings,
    required this.onSettingsChanged,
  });

  final AppSettings settings;
  final Future<void> Function(AppSettings) onSettingsChanged;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _formKey = GlobalKey<FormState>();
  final _accountController = TextEditingController();
  final _passwordController = TextEditingController();
  final _progressLogs = ValueNotifier<List<String>>(<String>[]);
  final _client = GiWifiClient();

  DeviceProfile _selectedProfile = DeviceProfile.windows;
  _ConnectionViewState _connectionState = _ConnectionViewState.disconnected;
  LoginSession? _session;
  List<String> _logs = <String>[];
  String _statusMessage = '等待登录';
  bool _isSubmitting = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _accountController.text = widget.settings.savedAccount;
    _passwordController.text = widget.settings.savedPassword;
  }

  @override
  void dispose() {
    _accountController.dispose();
    _passwordController.dispose();
    _progressLogs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isWide = MediaQuery.sizeOf(context).width >= 960;

    return Scaffold(
      appBar: AppBar(
        title: const Text('xGiWifi'),
        actions: <Widget>[
          PopupMenuButton<_AppMenuAction>(
            tooltip: '更多',
            onSelected: _handleMenuAction,
            itemBuilder: (BuildContext context) {
              return const <PopupMenuEntry<_AppMenuAction>>[
                PopupMenuItem<_AppMenuAction>(
                  value: _AppMenuAction.theme,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.palette_outlined),
                    title: Text('主题'),
                    subtitle: Text('跟随系统 / 浅色 / 深色'),
                  ),
                ),
                PopupMenuItem<_AppMenuAction>(
                  value: _AppMenuAction.about,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.info_outline),
                    title: Text('关于'),
                    subtitle: Text('项目说明与 GitHub'),
                  ),
                ),
              ];
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ColoredBox(
        color: theme.scaffoldBackgroundColor,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1180),
                child: isWide ? _buildWideLayout() : _buildNarrowLayout(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWideLayout() {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return _AnimatedCardFlow(
          items: _buildWideFlowItems(),
          spacing: 16,
          availableWidth: constraints.maxWidth,
        );
      },
    );
  }

  Widget _buildNarrowLayout() {
    return AnimatedSize(
      duration: _cardFlowDuration,
      curve: Curves.easeInOutCubic,
      alignment: Alignment.topCenter,
      child: Column(
        children: <Widget>[
          _buildStatusCard(),
          if (_session != null) ...<Widget>[
            const SizedBox(height: 16),
            _buildDetailsCard(),
          ],
          const SizedBox(height: 16),
          _buildLoginCard(),
          const SizedBox(height: 16),
          _buildLogsCard(),
        ],
      ),
    );
  }

  List<_FlowCardItem> _buildWideFlowItems() {
    return <_FlowCardItem>[
      _FlowCardItem(
        id: 'status-card',
        estimatedHeight: 184,
        child: _buildStatusCard(),
      ),
      if (_session != null)
        _FlowCardItem(
          id: 'details-card',
          estimatedHeight: 178,
          child: _buildDetailsCard(),
        ),
      _FlowCardItem(
        id: 'login-card',
        estimatedHeight: 430,
        child: _buildLoginCard(),
      ),
      _FlowCardItem(
        id: 'logs-card',
        estimatedHeight: 296,
        child: _buildLogsCard(),
      ),
    ];
  }

  Widget _buildStatusCard() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final statusColor = switch (_connectionState) {
      _ConnectionViewState.disconnected => colorScheme.outline,
      _ConnectionViewState.connecting => colorScheme.primary,
      _ConnectionViewState.connected => const Color(0xFF1E8E5A),
      _ConnectionViewState.failed => colorScheme.error,
    };
    final statusLabel = switch (_connectionState) {
      _ConnectionViewState.disconnected => '未连接',
      _ConnectionViewState.connecting => '正在登录',
      _ConnectionViewState.connected => '已连接',
      _ConnectionViewState.failed => '登录失败',
    };
    final statusIcon = switch (_connectionState) {
      _ConnectionViewState.disconnected => Icons.portable_wifi_off_outlined,
      _ConnectionViewState.connecting => Icons.sync,
      _ConnectionViewState.connected => Icons.verified_outlined,
      _ConnectionViewState.failed => Icons.error_outline,
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(statusIcon, color: statusColor),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        statusLabel,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: statusColor,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _statusMessage,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.dns_outlined,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.settings.baseUrl,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '连接详情',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 18),
            _buildDetailRow('终端', _session!.profile.label),
            const SizedBox(height: 12),
            _buildDetailRow('IP', _session!.ip),
            const SizedBox(height: 12),
            _buildDetailRow('时间', _formatTime(_session!.connectedAt)),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLoginCard() {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '账号登录',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '使用校园网账号登录，可选择终端类型占用在线设备名额。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              TextFormField(
                controller: _accountController,
                enabled: !_isSubmitting,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: '账号',
                  hintText: '输入手机号或账号',
                ),
                validator: (String? value) {
                  if (value == null || value.trim().isEmpty) {
                    return '请输入账号';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _passwordController,
                enabled: !_isSubmitting,
                obscureText: _obscurePassword,
                onFieldSubmitted: (_) => _submitLogin(),
                decoration: InputDecoration(
                  labelText: '密码',
                  suffixIcon: IconButton(
                    onPressed: _isSubmitting
                        ? null
                        : () {
                            setState(() {
                              _obscurePassword = !_obscurePassword;
                            });
                          },
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
                validator: (String? value) {
                  if (value == null || value.isEmpty) {
                    return '请输入密码';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),
              Text(
                '终端',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              SegmentedButton<DeviceProfile>(
                showSelectedIcon: false,
                segments: DeviceProfile.values
                    .map(
                      (DeviceProfile profile) => ButtonSegment<DeviceProfile>(
                        value: profile,
                        label: SizedBox(
                          width: 72,
                          child: Text(
                            profile.label,
                            textAlign: TextAlign.center,
                            softWrap: false,
                            overflow: TextOverflow.visible,
                          ),
                        ),
                      ),
                    )
                    .toList(),
                selected: <DeviceProfile>{_selectedProfile},
                onSelectionChanged: _isSubmitting
                    ? null
                    : (Set<DeviceProfile> selection) {
                        setState(() {
                          _selectedProfile = selection.first;
                        });
                      },
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _isSubmitting ? null : _submitLogin,
                icon: _isSubmitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.login_rounded),
                label: Text(_isSubmitting ? '登录中...' : '登录'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLogsCard() {
    final theme = Theme.of(context);
    final logText = _logs.isEmpty ? '暂无日志' : _logs.join('\n');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '日志',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '显示最近一次登录过程。',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '复制日志',
                  onPressed: _logs.isEmpty ? null : _copyLogs,
                  icon: const Icon(Icons.copy_all_outlined),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(minHeight: 180),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.45,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: SelectableText(
                logText,
                style: theme.textTheme.bodySmall?.copyWith(
                  height: 1.6,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleMenuAction(_AppMenuAction action) async {
    if (!mounted) {
      return;
    }

    switch (action) {
      case _AppMenuAction.theme:
        await _showThemeDialog();
        break;
      case _AppMenuAction.portal:
        // Temporarily disabled due to a cross-platform framework assertion
        // when opening the dialog.
        break;
      case _AppMenuAction.about:
        await _showAboutDialog();
        break;
    }
  }

  Future<void> _showThemeDialog() async {
    final selectedMode = await showDialog<ThemeMode>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('主题'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: ThemeMode.values.map((ThemeMode mode) {
              final isSelected = mode == widget.settings.themeMode;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(themeModeLabel(mode)),
                trailing: isSelected
                    ? Icon(
                        Icons.check_circle,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : const Icon(Icons.circle_outlined),
                onTap: () => Navigator.of(context).pop(mode),
              );
            }).toList(),
          ),
        );
      },
    );

    if (selectedMode == null || selectedMode == widget.settings.themeMode) {
      return;
    }

    await widget.onSettingsChanged(
      widget.settings.copyWith(themeMode: selectedMode),
    );
  }

  // ignore: unused_element
  Future<void> _showBaseUrlDialog() async {
    final controller = TextEditingController(text: widget.settings.baseUrl);
    String? errorText;

    final newValue = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder:
              (BuildContext context, void Function(void Function()) setState) {
                return AlertDialog(
                  title: const Text('Portal 地址'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '默认值为 $kDefaultBaseUrl',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: controller,
                        autofocus: true,
                        decoration: InputDecoration(
                          labelText: 'Base URL',
                          hintText: kDefaultBaseUrl,
                          errorText: errorText,
                        ),
                      ),
                    ],
                  ),
                  actions: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () {
                        try {
                          final normalized = normalizePortalBaseUrl(
                            controller.text,
                          );
                          Navigator.of(context).pop(normalized);
                        } on FormatException catch (error) {
                          setState(() {
                            errorText = error.message;
                          });
                        }
                      },
                      child: const Text('保存'),
                    ),
                  ],
                );
              },
        );
      },
    );

    controller.dispose();

    if (newValue == null || newValue == widget.settings.baseUrl) {
      return;
    }

    await widget.onSettingsChanged(widget.settings.copyWith(baseUrl: newValue));

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Portal 地址已更新为 $newValue')));
  }

  Future<void> _showAboutDialog() async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('关于'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'xGiWifi',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              const Text('一个用于校园网认证的第三方工具。'),
              const SizedBox(height: 12),
              Text(
                kPlaceholderGithubUrl,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
            FilledButton(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(this.context);
                final uri = Uri.parse(kPlaceholderGithubUrl);
                final launched = await launchUrl(
                  uri,
                  mode: LaunchMode.externalApplication,
                );
                if (!mounted) {
                  return;
                }
                if (!launched) {
                  messenger.showSnackBar(
                    const SnackBar(content: Text('无法打开 GitHub 地址')),
                  );
                }
              },
              child: const Text('打开 GitHub'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _submitLogin() async {
    if (_isSubmitting) {
      return;
    }
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final username = _accountController.text.trim();
    final password = _passwordController.text;

    await widget.onSettingsChanged(
      widget.settings.copyWith(savedAccount: username, savedPassword: password),
    );
    if (!mounted) {
      return;
    }

    _replaceLogs(<String>[]);
    setState(() {
      _isSubmitting = true;
      _connectionState = _ConnectionViewState.connecting;
      _session = null;
      _statusMessage = '正在连接 ${widget.settings.baseUrl}';
    });

    unawaited(_showProgressDialog());
    await Future<void>.delayed(Duration.zero);

    try {
      final result = await _client.login(
        baseUrl: widget.settings.baseUrl,
        profile: _selectedProfile,
        username: username,
        password: password,
        onLog: _appendLog,
        onBindConflict: _showBindDialog,
      );

      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }

      if (!mounted) {
        return;
      }

      setState(() {
        switch (result.outcome) {
          case LoginOutcome.success:
            _connectionState = _ConnectionViewState.connected;
            _statusMessage = result.info.isEmpty ? '连接已建立' : result.info;
            _session = result.session;
            break;
          case LoginOutcome.cancelled:
            _connectionState = _ConnectionViewState.disconnected;
            _statusMessage = result.info;
            _session = null;
            break;
          case LoginOutcome.failure:
            _connectionState = _ConnectionViewState.failed;
            _statusMessage = result.info.isEmpty ? '认证未通过' : result.info;
            _session = null;
            break;
        }
      });
    } catch (error) {
      _appendLog('[ERROR] $error');
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _connectionState = _ConnectionViewState.failed;
        _session = null;
        _statusMessage = '请求异常: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Future<void> _showProgressDialog() {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Text('正在登录'),
            content: ValueListenableBuilder<List<String>>(
              valueListenable: _progressLogs,
              builder:
                  (BuildContext context, List<String> logs, Widget? child) {
                    final preview = logs.isEmpty
                        ? '准备开始请求...'
                        : logs.takeLast(5).join('\n');

                    return SizedBox(
                      width: 360,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Row(
                            children: <Widget>[
                              SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                ),
                              ),
                              SizedBox(width: 12),
                              Expanded(child: Text('认证流程进行中')),
                            ],
                          ),
                          const SizedBox(height: 18),
                          SelectableText(
                            preview,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    );
                  },
            ),
          ),
        );
      },
    );
  }

  Future<bool> _showBindDialog(String message) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('设备冲突'),
          content: Text(message.isEmpty ? '当前账号已在其他设备登录，是否替换为本设备？' : message),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('继续'),
            ),
          ],
        );
      },
    );

    return result ?? false;
  }

  void _appendLog(String entry) {
    final nextLogs = <String>[..._logs, entry];
    setState(() {
      _logs = nextLogs;
    });
    _progressLogs.value = nextLogs;
  }

  void _replaceLogs(List<String> entries) {
    setState(() {
      _logs = entries;
    });
    _progressLogs.value = entries;
  }

  Future<void> _copyLogs() async {
    await Clipboard.setData(ClipboardData(text: _logs.join('\n')));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('日志已复制')));
  }

  String _formatTime(DateTime value) {
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    final second = value.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }
}

class _FlowCardItem {
  const _FlowCardItem({
    required this.id,
    required this.child,
    required this.estimatedHeight,
  });

  final Object id;
  final Widget child;
  final double estimatedHeight;
}

class _AnimatedCardFlow extends StatefulWidget {
  const _AnimatedCardFlow({
    required this.items,
    required this.spacing,
    required this.availableWidth,
  });

  final List<_FlowCardItem> items;
  final double spacing;
  final double availableWidth;

  @override
  State<_AnimatedCardFlow> createState() => _AnimatedCardFlowState();
}

class _AnimatedCardFlowState extends State<_AnimatedCardFlow> {
  final Map<Object, double> _heights = <Object, double>{};

  @override
  Widget build(BuildContext context) {
    final columnWidth = (widget.availableWidth - widget.spacing) / 2;
    final layout = _buildLayout(columnWidth);

    return AnimatedContainer(
      duration: _cardFlowDuration,
      curve: Curves.easeInOutCubic,
      height: layout.totalHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: widget.items.map((item) {
          final position = layout.positions[item.id]!;
          return AnimatedPositioned(
            key: ValueKey<Object>(item.id),
            duration: _cardFlowDuration,
            curve: Curves.easeInOutCubic,
            left: position.dx,
            top: position.dy,
            width: columnWidth,
            child: _MeasureSize(
              onChange: (Size size) {
                final nextHeight = size.height;
                if (_heights[item.id] == nextHeight) {
                  return;
                }
                setState(() {
                  _heights[item.id] = nextHeight;
                });
              },
              child: KeyedSubtree(
                key: ValueKey<Object>(item.id),
                child: item.child,
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  _FlowLayoutData _buildLayout(double columnWidth) {
    final positions = <Object, Offset>{};
    var leftHeight = 0.0;
    var rightHeight = 0.0;

    for (final item in widget.items) {
      final itemHeight = _heights[item.id] ?? item.estimatedHeight;
      final placeOnLeft = leftHeight <= rightHeight;

      if (placeOnLeft) {
        positions[item.id] = Offset(0, leftHeight);
        leftHeight += itemHeight + widget.spacing;
      } else {
        positions[item.id] = Offset(columnWidth + widget.spacing, rightHeight);
        rightHeight += itemHeight + widget.spacing;
      }
    }

    return _FlowLayoutData(
      positions: positions,
      totalHeight: math.max(
        0,
        math.max(leftHeight, rightHeight) - widget.spacing,
      ),
    );
  }
}

class _FlowLayoutData {
  const _FlowLayoutData({required this.positions, required this.totalHeight});

  final Map<Object, Offset> positions;
  final double totalHeight;
}

class _MeasureSize extends SingleChildRenderObjectWidget {
  const _MeasureSize({required this.onChange, required super.child});

  final ValueChanged<Size> onChange;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderMeasureSize(onChange);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderMeasureSize renderObject,
  ) {
    renderObject.onChange = onChange;
  }
}

class _RenderMeasureSize extends RenderProxyBox {
  _RenderMeasureSize(this.onChange);

  ValueChanged<Size> onChange;
  Size? _oldSize;

  @override
  void performLayout() {
    super.performLayout();

    final newSize = child?.size ?? Size.zero;
    if (_oldSize == newSize) {
      return;
    }

    _oldSize = newSize;
    WidgetsBinding.instance.addPostFrameCallback((_) => onChange(newSize));
  }
}

extension on List<String> {
  Iterable<String> takeLast(int count) {
    if (length <= count) {
      return this;
    }
    return skip(length - count);
  }
}
