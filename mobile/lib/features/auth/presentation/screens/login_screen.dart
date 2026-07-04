import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/errors/error_messages.dart';
import 'package:suuqii/features/auth/data/auth_remote_data_source.dart';
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
  String? _phoneError;
  String? _pwdError;
  String? _formError;

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
                    l.welcomeBack,
                    style: theme.textTheme.displaySmall,
                  ),
                  const SizedBox(height: SuuqSpacing.xs),
                  Text(
                    l.loginSubtitle,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: SuuqSpacing.xl),
                  TextField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                    onChanged: (_) {
                      if (_phoneError != null) {
                        setState(() => _phoneError = null);
                      }
                    },
                    decoration: InputDecoration(
                      labelText: l.phone,
                      errorText: _phoneError,
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
                    onChanged: (_) {
                      if (_pwdError != null) setState(() => _pwdError = null);
                    },
                    onSubmitted: (_) => _submit(l),
                    decoration: InputDecoration(
                      labelText: l.password,
                      errorText: _pwdError,
                      prefixIcon: const Icon(
                        Icons.lock_outline_rounded,
                        size: 20,
                      ),
                      suffixIcon: IconButton(
                        onPressed: () => setState(() => _obscure = !_obscure),
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                  if (_formError != null) ...[
                    const SizedBox(height: SuuqSpacing.sm),
                    _FormError(message: _formError!),
                  ],
                  const SizedBox(height: SuuqSpacing.lg),
                  FilledButton(
                    onPressed: _busy ? null : () => _submit(l),
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
                    onPressed:
                        _busy ? null : () => context.go('/register-shop'),
                    child: Text(l.createNewShop),
                  ),
                  TextButton(
                    onPressed:
                        _busy ? null : () => context.go('/accept-invite'),
                    child: Text(l.joinShopWithCode),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit(AppLocalizations l) async {
    final phone = _phone.text.trim();
    final pwd = _pwd.text;
    final phoneEmpty = phone.isEmpty;
    final pwdEmpty = pwd.isEmpty;
    if (phoneEmpty || pwdEmpty) {
      setState(() {
        _phoneError = phoneEmpty ? l.enterPhoneAndPassword : null;
        _pwdError = pwdEmpty ? l.enterPhoneAndPassword : null;
        _formError = null;
      });
      return;
    }

    setState(() {
      _busy = true;
      _formError = null;
    });
    final router = GoRouter.of(context);
    try {
      await ref.read(authControllerProvider.notifier).login(
            phone: phone,
            password: pwd,
          );
      router.go('/pos');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _formError = error is AuthException && error.status == 401
            ? l.errorInvalidCredentials
            : messageForError(error, l);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _FormError extends StatelessWidget {
  const _FormError({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(SuuqSpacing.sm),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(SuuqRadius.sm),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: scheme.onErrorContainer,
          ),
          const SizedBox(width: SuuqSpacing.xs),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
