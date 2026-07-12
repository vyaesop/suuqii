import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/http/dio_client.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/features/auth/data/auth_remote_data_source.dart';
import 'package:suuqii/shared/widgets/empty_state.dart';
import 'package:suuqii/shared/widgets/section_card.dart';
import 'package:suuqii/shared/widgets/sheet_handle.dart';
import 'package:suuqii/shared/widgets/status_pill.dart';

final _authApiProvider = Provider<AuthRemoteDataSource>(
  (ref) => AuthRemoteDataSource(ref.watch(dioProvider)),
);

final _employeesProvider = FutureProvider.autoDispose<List<_Employee>>(
  (ref) async {
    final api = ref.watch(_authApiProvider);
    final rows = await api.listShopUsers();
    return rows.map(_Employee.fromJson).toList();
  },
);

class _Employee {
  _Employee({
    required this.id,
    required this.name,
    required this.phone,
    required this.role,
    required this.isActive,
  });

  factory _Employee.fromJson(Map<String, dynamic> j) => _Employee(
        id: j['id'] as String,
        name: j['name'] as String,
        phone: j['phone'] as String,
        role: j['role'] as String,
        isActive: j['is_active'] as bool,
      );

  final String id;
  final String name;
  final String phone;
  final String role;
  final bool isActive;
}

class EmployeesScreen extends ConsumerWidget {
  const EmployeesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final async = ref.watch(_employeesProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l.settingsEmployees)),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.person_add_alt_1_rounded),
        onPressed: () => _invite(context, ref),
        label: Text(l.employeesInviteFab),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.refresh(_employeesProvider.future),
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => EmptyState(
            icon: Icons.error_outline,
            title: l.employeesLoadFailedTitle,
            message: context.errorMessage(e),
          ),
          data: (list) {
            if (list.isEmpty) {
              return EmptyState(
                icon: Icons.group_outlined,
                title: l.employeesEmptyTitle,
                message: l.employeesEmptyMessage,
                action: FilledButton.icon(
                  icon: const Icon(Icons.person_add_alt_1_rounded),
                  onPressed: () => _invite(context, ref),
                  label: Text(l.employeesInviteCta),
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(
                SuuqSpacing.md,
                SuuqSpacing.xs,
                SuuqSpacing.md,
                96,
              ),
              itemCount: list.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(height: SuuqSpacing.xs),
              itemBuilder: (_, i) => _EmployeeRow(employee: list[i]),
            );
          },
        ),
      ),
    );
  }

  Future<void> _invite(BuildContext context, WidgetRef ref) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _InviteSheet(),
    );
    if ((result ?? false) && context.mounted) {
      // ignore: unused_result
      ref.refresh(_employeesProvider);
    }
  }
}

class _EmployeeRow extends StatelessWidget {
  const _EmployeeRow({required this.employee});
  final _Employee employee;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final isOwner = employee.role == 'owner';
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(SuuqRadius.md),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(SuuqRadius.md),
          border: Border.all(color: scheme.outlineVariant),
        ),
        padding: const EdgeInsets.all(SuuqSpacing.md),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isOwner
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(SuuqRadius.sm),
              ),
              child: Icon(
                isOwner ? Icons.shield_outlined : Icons.person_outline_rounded,
                color: isOwner
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: SuuqSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(employee.name, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(employee.phone, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(width: SuuqSpacing.sm),
            if (!employee.isActive)
              StatusPill(
                label: l.employeesPillPending,
                intent: PillIntent.warning,
              )
            else
              StatusPill(
                label: _roleLabel(l, employee.role).toUpperCase(),
                intent: isOwner ? PillIntent.info : PillIntent.neutral,
              ),
          ],
        ),
      ),
    );
  }

  String _roleLabel(AppLocalizations l, String role) {
    switch (role) {
      case 'owner':
        return l.roleOwner;
      case 'cashier':
        return l.roleCashier;
      default:
        return role;
    }
  }
}

class _InviteSheet extends ConsumerStatefulWidget {
  const _InviteSheet();
  @override
  ConsumerState<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends ConsumerState<_InviteSheet> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _code;
  String? _expiresAt;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (_code != null) {
      return SuuqSheet(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 64,
                height: 64,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.check_rounded,
                  size: 36,
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(height: SuuqSpacing.sm),
            Center(
              child: Text(
                l.employeesInviteReadyTitle,
                style: theme.textTheme.titleLarge,
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                l.employeesInviteShareCode(_name.text.trim()),
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: SuuqSpacing.lg),
            SectionCard(
              padding: const EdgeInsets.symmetric(
                horizontal: SuuqSpacing.md,
                vertical: SuuqSpacing.lg,
              ),
              child: Column(
                children: [
                  Text(
                    _code!,
                    style: theme.textTheme.displayMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 6,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: SuuqSpacing.xs),
                  Text(
                    _expiresAt == null
                        ? l.employeesInviteExpiresSoon
                        : l.employeesInviteExpiresAt(_expiresAt!),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(height: SuuqSpacing.md),
            Text(
              l.employeesInviteInstructions,
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: SuuqSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _code!));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(l.employeesCodeCopied)),
                      );
                    },
                    label: Text(l.employeesCopyCode),
                  ),
                ),
                const SizedBox(width: SuuqSpacing.sm),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(l.commonDone),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return SuuqSheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l.employeesInviteSheetTitle, style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            l.employeesInviteSheetSubtitle,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: SuuqSpacing.md),
          TextField(
            controller: _name,
            decoration: InputDecoration(
              labelText: l.employeesNameLabel,
              prefixIcon: const Icon(Icons.person_outline_rounded),
            ),
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: SuuqSpacing.sm),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              labelText: l.phone,
              prefixIcon: const Icon(Icons.phone_iphone_rounded),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: SuuqSpacing.sm),
            Text(_error!, style: TextStyle(color: scheme.error)),
          ],
          const SizedBox(height: SuuqSpacing.lg),
          SizedBox(
            height: 56,
            child: FilledButton.icon(
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.send_rounded),
              onPressed: _busy ? null : _submit,
              label: Text(l.employeesGenerateCode),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final l = context.l10n;
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    if (name.isEmpty || phone.isEmpty) {
      setState(() => _error = l.employeesNamePhoneRequired);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(_authApiProvider);
      final res = await api.invite(name: name, phone: phone);
      if (!mounted) return;
      setState(() {
        _code = res.code;
        _expiresAt = _formatExpiry(res.expiresAt);
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = localizedErrorMessage(l, e);
        _busy = false;
      });
    }
  }

  String? _formatExpiry(String iso) {
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return iso;
    return context.timeShort(dt);
  }
}
