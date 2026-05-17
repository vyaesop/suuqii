import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final isOwner = auth is Authenticated && auth.role == 'owner';

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
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
            const _SectionHeader('Shop'),
            ListTile(
              leading: const Icon(Icons.insights_outlined),
              title: const Text('Dashboard'),
              onTap: () => context.push('/owner'),
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Audit log'),
              onTap: () => context.push('/audit'),
            ),
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('Expenses'),
              onTap: () => context.push('/expenses'),
            ),
            const Divider(),
          ],
          const _SectionHeader('Account'),
          const ListTile(
            leading: Icon(Icons.language),
            title: Text('Language'),
            subtitle: Text('English (en) — switching coming soon'),
          ),
          const ListTile(
            leading: Icon(Icons.brightness_6_outlined),
            title: Text('Theme'),
            subtitle: Text('Follows system'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text(
              'Log out',
              style: TextStyle(color: Colors.red),
            ),
            onTap: () async {
              await ref.read(authControllerProvider.notifier).logout();
              if (context.mounted) context.go('/login');
            },
          ),
        ],
      ),
    );
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
