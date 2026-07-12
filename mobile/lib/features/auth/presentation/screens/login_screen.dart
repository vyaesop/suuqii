import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
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
    final l = context.l10n;
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
                    l.loginWelcomeTitle,
                    style: theme.textTheme.displaySmall,
                  ),
                  const SizedBox(height: SuuqSpacing.xs),
                  Text(
                    l.loginWelcomeSubtitle,
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
                    child: Text(l.loginHaveInviteCode),
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
    final l = context.l10n;
    if (_phone.text.trim().isEmpty || _pwd.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.loginEnterPhonePassword)),
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
    } on PendingSyncException catch (e) {
      // Signing into a different shop would wipe unsynced local records.
      final discard = await _confirmDiscard(e.pendingCount);
      if (discard) {
        try {
          await ref.read(authControllerProvider.notifier).login(
                phone: _phone.text.trim(),
                password: _pwd.text,
                force: true,
              );
          router.go('/pos');
        } catch (e) {
          messenger.showSnackBar(
            SnackBar(content: Text(localizedErrorMessage(l, e))),
          );
        }
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(localizedErrorMessage(l, e))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmDiscard(int count) async {
    if (!mounted) return false;
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final l = ctx.l10n;
        return AlertDialog(
          title: Text(l.loginUnsyncedTitle),
          content: Text(l.loginUnsyncedBody(count)),
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
              child: Text(l.loginSwitchAnyway),
            ),
          ],
        );
      },
    );
    return discard ?? false;
  }
}
