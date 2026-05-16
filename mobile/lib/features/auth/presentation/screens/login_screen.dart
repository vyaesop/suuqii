import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../l10n/app_localizations.dart';
import '../controllers/auth_controller.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _phone = TextEditingController();
  final _pwd = TextEditingController();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(l.appTitle, style: Theme.of(context).textTheme.displaySmall),
              const SizedBox(height: 32),
              TextField(controller: _phone, decoration: InputDecoration(labelText: l.phone),
                keyboardType: TextInputType.phone),
              const SizedBox(height: 12),
              TextField(controller: _pwd, decoration: InputDecoration(labelText: l.password),
                obscureText: true),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: Text(l.login),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => context.go('/register-shop'),
                child: Text(l.createNewShop),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      await ref.read(authControllerProvider.notifier).login(_phone.text, _pwd.text);
      if (mounted) context.go('/pos');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
