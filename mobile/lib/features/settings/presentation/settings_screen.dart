import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/l10n/locale_controller.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/settings/presentation/controllers/theme_controller.dart';
import 'package:suuqii/features/settings/presentation/shop_switcher_sheet.dart';

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
                l.settingsProfileSubtitle(
                  _roleLabel(l, auth.role),
                  auth.shopName,
                ),
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
              leading: const Icon(Icons.storefront_outlined),
              title: Text(l.settingsShopSettings),
              subtitle: Text(l.settingsShopSettingsSubtitle),
              onTap: () => context.push('/shop-settings'),
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
            ListTile(
              leading: const Icon(Icons.swap_horiz_rounded),
              title: Text(l.shopSwitcherOpen),
              subtitle: Text(l.shopSwitcherSubtitle),
              onTap: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => const ShopSwitcherSheet(),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: Text(l.dataTitle),
              subtitle: Text(l.dataExportHint),
              onTap: () => context.push('/data'),
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
          const _ThemeTile(),
          const Divider(),
          Semantics(
            button: true,
            child: ListTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: Text(
                l.settingsLogout,
                style: const TextStyle(color: Colors.red),
              ),
              onTap: () => _logout(context, ref),
            ),
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
    // Always confirm first: with nothing pending, logout silently wipes the
    // local database, so the user must opt in explicitly. The pending-sync
    // dialog below still guards unsynced data separately.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.settingsLogoutConfirmTitle),
        content: Text(l.settingsLogoutConfirmBody),
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
            child: Text(l.settingsLogout),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false) || !context.mounted) return;
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

/// Language selector: System default / English / Afaan Oromoo / አማርኛ,
/// persisted via [localeControllerProvider]. The explicit device-level choice
/// wins over the shop locale chosen at registration.
class _LanguageTile extends ConsumerWidget {
  const _LanguageTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final locale = ref.watch(localeControllerProvider);
    final current = switch (locale?.languageCode) {
      'en' => l.settingsLanguageEnglish,
      'om' => l.settingsLanguageOromo,
      'am' => l.settingsLanguageAmharic,
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
                RadioListTile<_LanguageChoice>(
                  value: _LanguageChoice.amharic,
                  title: Text(l.settingsLanguageAmharic),
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
            _LanguageChoice.amharic => const Locale('am'),
          },
        );
  }

  _LanguageChoice _choiceFor(Locale? locale) => switch (locale?.languageCode) {
        'en' => _LanguageChoice.english,
        'om' => _LanguageChoice.oromo,
        'am' => _LanguageChoice.amharic,
        _ => _LanguageChoice.system,
      };
}

enum _LanguageChoice { system, english, oromo, amharic }

/// Theme selector: System / Light / Dark, persisted via
/// [themeModeControllerProvider].
class _ThemeTile extends ConsumerWidget {
  const _ThemeTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final mode = ref.watch(themeModeControllerProvider);
    return ListTile(
      leading: const Icon(Icons.brightness_6_outlined),
      title: Text(l.settingsTheme),
      subtitle: Text(_label(l, mode)),
      onTap: () => _pickTheme(context, ref, mode),
    );
  }

  String _label(AppLocalizations l, ThemeMode mode) => switch (mode) {
        ThemeMode.system => l.settingsThemeSystem,
        ThemeMode.light => l.settingsThemeLight,
        ThemeMode.dark => l.settingsThemeDark,
      };

  Future<void> _pickTheme(
    BuildContext context,
    WidgetRef ref,
    ThemeMode active,
  ) async {
    final l = context.l10n;
    final choice = await showDialog<ThemeMode>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l.settingsTheme),
        children: [
          RadioGroup<ThemeMode>(
            groupValue: active,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<ThemeMode>(
                  value: ThemeMode.system,
                  title: Text(l.settingsThemeSystem),
                ),
                RadioListTile<ThemeMode>(
                  value: ThemeMode.light,
                  title: Text(l.settingsThemeLight),
                ),
                RadioListTile<ThemeMode>(
                  value: ThemeMode.dark,
                  title: Text(l.settingsThemeDark),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (choice == null) return;
    await ref.read(themeModeControllerProvider.notifier).setMode(choice);
  }
}

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
