import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/l10n/app_localizations.dart';
import 'package:suuqii/shared/widgets/suuq_logo.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _phone = TextEditingController();
  final _pwd = TextEditingController();
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    _phone.dispose();
    _pwd.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: SuuqSpacing.lg,
              vertical: SuuqSpacing.xl,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: SuuqSpacing.xxl),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: SuuqLogo(size: 36),
                  ),
                  const SizedBox(height: SuuqSpacing.xxl),
                  Text(
                    'Welcome back',
                    style: theme.textTheme.displaySmall,
                  ),
                  const SizedBox(height: SuuqSpacing.xs),
                  Text(
                    'Sign in to your shop to keep selling.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: SuuqSpacing.xl),
                  TextField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: l.phone,
                      prefixIcon: const Icon(
                        Icons.phone_iphone_rounded,
                        size: 20,
                      ),
                    ),
                  ),
                  const SizedBox(height: SuuqSpacing.sm),
                  TextField(
                    controller: _pwd,
                    obscureText: _obscure,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: l.password,
                      prefixIcon: const Icon(
                        Icons.lock_outline_rounded,
                        size: 20,
                      ),
                      suffixIcon: IconButton(
                        onPressed: () =>
                            setState(() => _obscure = !_obscure),
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: SuuqSpacing.lg),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(l.login),
                  ),
                  const SizedBox(height: SuuqSpacing.sm),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => context.go('/register-shop'),
                    child: Text(l.createNewShop),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => context.go('/accept-invite'),
                    child: const Text('I have an invite code'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (_phone.text.trim().isEmpty || _pwd.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter phone and password')),
      );
      return;
    }
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      await ref.read(authControllerProvider.notifier).login(
            phone: _phone.text.trim(),
            password: _pwd.text,
          );
      router.go('/pos');
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
