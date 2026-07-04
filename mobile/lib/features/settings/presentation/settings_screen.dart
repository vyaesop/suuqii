import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:suuqii/core/locale/locale_controller.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/l10n/app_localizations.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final isOwner = auth is Authenticated && auth.role == 'owner';
    final locale = ref.watch(localeControllerProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l.navSettings)),
      body: ListView(
        children: [
          if (auth is Authenticated)
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text(auth.userName),
              subtitle: Text('${auth.role} · ${auth.shopName}'),
            ),
          const Divider(),
          if (isOwner) ...[
            _SectionHeader(l.settingsShop),
            ListTile(
              leading: const Icon(Icons.insights_outlined),
              title: Text(l.navDashboard),
              onTap: () => context.push('/owner'),
            ),
            ListTile(
              leading: const Icon(Icons.bar_chart_rounded),
              title: const Text('Reports'),
              subtitle: const Text('Sales over time, top products'),
              onTap: () => context.push('/reports'),
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Audit log'),
              onTap: () => context.push('/audit'),
            ),
            ListTile(
              leading: const Icon(Icons.group_outlined),
              title: const Text('Employees'),
              subtitle: const Text('Invite and manage cashiers'),
              onTap: () => context.push('/employees'),
            ),
            ListTile(
              leading: const Icon(Icons.timelapse_rounded),
              title: const Text('Open shifts'),
              subtitle: const Text('Force-close stale shifts'),
              onTap: () => context.push('/open-shifts'),
            ),
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: Text(l.expenses),
              onTap: () => context.push('/expenses'),
            ),
            const Divider(),
          ],
          _SectionHeader(l.settingsSales),
          ListTile(
            leading: const Icon(Icons.receipt_outlined),
            title: Text(l.recentSales),
            subtitle: const Text('View & refund recent transactions'),
            onTap: () => context.push('/recent-sales'),
          ),
          const Divider(),
          _SectionHeader(l.settingsAccount),
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(l.settingsLanguage),
            subtitle: Text(_localeLabel(l, locale)),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _pickLanguage(context, ref, l, locale),
          ),
          ListTile(
            leading: const Icon(Icons.brightness_6_outlined),
            title: Text(l.settingsTheme),
            subtitle: Text(l.themeFollowsSystem),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: Text(
              l.logOut,
              style: const TextStyle(color: Colors.red),
            ),
            onTap: () => _confirmLogout(context, ref, l),
          ),
        ],
      ),
    );
  }

  String _localeLabel(AppLocalizations l, Locale? locale) {
    switch (locale?.languageCode) {
      case 'en':
        return l.languageEnglish;
      case 'om':
        return l.languageOromo;
      default:
        return l.languageSystem;
    }
  }

  Future<void> _pickLanguage(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l,
    Locale? current,
  ) async {
    final selected = await showModalBottomSheet<Object>(
      context: context,
      builder: (ctx) {
        Widget option(String label, Locale? value, String? code) {
          final selected = current?.languageCode == code;
          return ListTile(
            title: Text(label),
            trailing: selected
                ? Icon(
                    Icons.check_rounded,
                    color: Theme.of(ctx).colorScheme.primary,
                  )
                : null,
            onTap: () => Navigator.pop(ctx, value ?? _systemSentinel),
          );
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l.selectLanguage,
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                ),
              ),
              option(l.languageSystem, null, null),
              option(l.languageEnglish, const Locale('en'), 'en'),
              option(l.languageOromo, const Locale('om'), 'om'),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    if (selected == null) return;
    final locale = selected == _systemSentinel ? null : selected as Locale;
    await ref.read(localeControllerProvider.notifier).setLocale(locale);
  }

  Future<void> _confirmLogout(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.logOutConfirmTitle),
        content: Text(l.logOutConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.logOut),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(authControllerProvider.notifier).logout();
    if (context.mounted) context.go('/login');
  }
}

/// Sentinel returned by the language picker to represent "system default",
/// distinguishing it from a dismissed sheet (which returns null).
const _systemSentinel = 'system';

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
