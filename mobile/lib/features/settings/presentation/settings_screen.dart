import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/l10n/locale_controller.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final isOwner = auth is Authenticated && auth.role == 'owner';

    return Scaffold(
      appBar: AppBar(title: Text(l.settingsTitle)),
      body: ListView(
        children: [
          if (auth is Authenticated)
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text(auth.userName),
              subtitle: Text(
                l.settingsProfileSubtitle(_roleLabel(l, auth.role), auth.shopName),
              ),
            ),
          const Divider(),
          if (isOwner) ...[
            _SectionHeader(l.settingsSectionShop),
            ListTile(
              leading: const Icon(Icons.insights_outlined),
              title: Text(l.navDashboard),
              onTap: () => context.push('/owner'),
            ),
            ListTile(
              leading: const Icon(Icons.bar_chart_rounded),
              title: Text(l.settingsReports),
              subtitle: Text(l.settingsReportsSubtitle),
              onTap: () => context.push('/reports'),
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: Text(l.settingsAuditLog),
              onTap: () => context.push('/audit'),
            ),
            ListTile(
              leading: const Icon(Icons.group_outlined),
              title: Text(l.settingsEmployees),
              subtitle: Text(l.settingsEmployeesSubtitle),
              onTap: () => context.push('/employees'),
            ),
            ListTile(
              leading: const Icon(Icons.timelapse_rounded),
              title: Text(l.settingsOpenShifts),
              subtitle: Text(l.settingsOpenShiftsSubtitle),
              onTap: () => context.push('/open-shifts'),
            ),
            const Divider(),
          ],
          _SectionHeader(l.settingsSectionSales),
          ListTile(
            leading: const Icon(Icons.receipt_outlined),
            title: Text(l.settingsRecentSales),
            subtitle: Text(l.settingsRecentSalesSubtitle),
            onTap: () => context.push('/recent-sales'),
          ),
          // Expenses are not owner-only: cashiers may record small expenses
          // (over-threshold entries trigger the owner-PIN challenge).
          ListTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: Text(l.expenses),
            onTap: () => context.push('/expenses'),
          ),
          const Divider(),
          _SectionHeader(l.settingsSectionAccount),
          const _LanguageTile(),
          ListTile(
            leading: const Icon(Icons.brightness_6_outlined),
            title: Text(l.settingsTheme),
            subtitle: Text(l.settingsThemeSystem),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: Text(
              l.settingsLogout,
              style: const TextStyle(color: Colors.red),
            ),
            onTap: () => _logout(context, ref),
          ),
        ],
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

  Future<void> _logout(BuildContext context, WidgetRef ref) async {
    final l = context.l10n;
    final router = GoRouter.of(context);
    try {
      await ref.read(authControllerProvider.notifier).logout();
      router.go('/login');
    } on PendingSyncException catch (e) {
      if (!context.mounted) return;
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l.settingsUnsyncedTitle),
          content: Text(l.settingsUnsyncedBody(e.pendingCount)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.commonCancel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l.settingsLogoutAnyway),
            ),
          ],
        ),
      );
      if (!(discard ?? false)) return;
      await ref.read(authControllerProvider.notifier).logout(force: true);
      router.go('/login');
    }
  }
}

/// Language selector: System default / English / Afaan Oromoo, persisted via
/// [localeControllerProvider]. The explicit device-level choice wins over the
/// shop locale chosen at registration.
class _LanguageTile extends ConsumerWidget {
  const _LanguageTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final locale = ref.watch(localeControllerProvider);
    final current = switch (locale?.languageCode) {
      'en' => l.settingsLanguageEnglish,
      'om' => l.settingsLanguageOromo,
      _ => l.settingsLanguageSystem,
    };
    return ListTile(
      leading: const Icon(Icons.language),
      title: Text(l.settingsLanguage),
      subtitle: Text(current),
      onTap: () => _pickLanguage(context, ref, locale),
    );
  }

  Future<void> _pickLanguage(
    BuildContext context,
    WidgetRef ref,
    Locale? active,
  ) async {
    final l = context.l10n;
    final choice = await showDialog<_LanguageChoice>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l.settingsLanguage),
        children: [
          RadioGroup<_LanguageChoice>(
            groupValue: _choiceFor(active),
            onChanged: (v) => Navigator.pop(ctx, v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<_LanguageChoice>(
                  value: _LanguageChoice.system,
                  title: Text(l.settingsLanguageSystem),
                ),
                RadioListTile<_LanguageChoice>(
                  value: _LanguageChoice.english,
                  title: Text(l.settingsLanguageEnglish),
                ),
                RadioListTile<_LanguageChoice>(
                  value: _LanguageChoice.oromo,
                  title: Text(l.settingsLanguageOromo),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (choice == null) return;
    await ref.read(localeControllerProvider.notifier).setLocale(
          switch (choice) {
            _LanguageChoice.system => null,
            _LanguageChoice.english => const Locale('en'),
            _LanguageChoice.oromo => const Locale('om'),
          },
        );
  }

  _LanguageChoice _choiceFor(Locale? locale) => switch (locale?.languageCode) {
        'en' => _LanguageChoice.english,
        'om' => _LanguageChoice.oromo,
        _ => _LanguageChoice.system,
      };
}

enum _LanguageChoice { system, english, oromo }

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}
