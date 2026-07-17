import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/phone.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/shared/widgets/suuq_logo.dart';

class RegisterShopScreen extends ConsumerStatefulWidget {
  const RegisterShopScreen({super.key});

  @override
  ConsumerState<RegisterShopScreen> createState() => _RegisterShopScreenState();
}

class _RegisterShopScreenState extends ConsumerState<RegisterShopScreen> {
  final _formKey = GlobalKey<FormState>();
  final _shopName = TextEditingController();
  final _ownerName = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _pin = TextEditingController();
  String _shopType = 'regular';
  bool _busy = false;

  @override
  void dispose() {
    _shopName.dispose();
    _ownerName.dispose();
    _phone.dispose();
    _password.dispose();
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.go('/login'),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(
            horizontal: SuuqSpacing.lg,
            vertical: SuuqSpacing.md,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: SuuqLogo(size: 30),
                  ),
                  const SizedBox(height: SuuqSpacing.xl),
                  Text(l.registerTitle, style: theme.textTheme.displaySmall),
                  const SizedBox(height: SuuqSpacing.xs),
                  Text(
                    l.registerSubtitle,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: SuuqSpacing.xl),
                  _Group(
                    title: l.registerShopTypeGroup,
                    children: [
                      _ShopTypeSelector(
                        value: _shopType,
                        onChanged: (v) => setState(() => _shopType = v),
                      ),
                    ],
                  ),
                  const SizedBox(height: SuuqSpacing.md),
                  _Group(
                    title: l.registerShopGroup,
                    children: [
                      TextFormField(
                        controller: _shopName,
                        decoration: InputDecoration(
                          labelText: l.registerShopNameLabel,
                          prefixIcon: Icon(
                            _shopType == 'bakery'
                                ? Icons.bakery_dining_rounded
                                : Icons.storefront_rounded,
                            size: 20,
                          ),
                        ),
                        validator: _req,
                      ),
                    ],
                  ),
                  const SizedBox(height: SuuqSpacing.md),
                  _Group(
                    title: l.registerYouGroup,
                    children: [
                      TextFormField(
                        controller: _ownerName,
                        decoration: InputDecoration(
                          labelText: l.registerYourNameLabel,
                          prefixIcon: const Icon(
                            Icons.person_outline_rounded,
                            size: 20,
                          ),
                        ),
                        validator: _req,
                      ),
                      const SizedBox(height: SuuqSpacing.sm),
                      TextFormField(
                        controller: _phone,
                        keyboardType: TextInputType.phone,
                        decoration: InputDecoration(
                          labelText: l.phone,
                          hintText: l.registerPhoneHint,
                          prefixIcon: const Icon(
                            Icons.phone_iphone_rounded,
                            size: 20,
                          ),
                        ),
                        validator: _validPhone,
                      ),
                    ],
                  ),
                  const SizedBox(height: SuuqSpacing.md),
                  _Group(
                    title: l.registerSecurityGroup,
                    children: [
                      TextFormField(
                        controller: _password,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: l.password,
                          helperText: l.registerPasswordHelper,
                          prefixIcon: const Icon(
                            Icons.lock_outline_rounded,
                            size: 20,
                          ),
                        ),
                        validator: (v) => (v == null || v.length < 8)
                            ? l.registerPasswordMin
                            : null,
                      ),
                      const SizedBox(height: SuuqSpacing.sm),
                      TextFormField(
                        controller: _pin,
                        keyboardType: TextInputType.number,
                        obscureText: true,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(8),
                        ],
                        decoration: InputDecoration(
                          labelText: l.registerOwnerPinLabel,
                          helperText: l.registerOwnerPinHelper,
                          prefixIcon: const Icon(
                            Icons.pin_outlined,
                            size: 20,
                          ),
                        ),
                        validator: (v) =>
                            (v == null || v.length < 4 || v.length > 8)
                                ? l.registerOwnerPinInvalid
                                : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: SuuqSpacing.xl),
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
                        : Text(l.registerCreateShopCta),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String? _req(String? v) =>
      (v == null || v.trim().isEmpty) ? context.l10n.commonRequired : null;

  String? _validPhone(String? v) {
    if (v == null || v.trim().isEmpty) return context.l10n.commonRequired;
    return normalizeEthiopianPhone(v) == null
        ? context.l10n.phoneInvalid
        : null;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    final l = context.l10n;
    final locale = Localizations.localeOf(context).languageCode;
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      await ref.read(authControllerProvider.notifier).registerShop(
            shopName: _shopName.text.trim(),
            ownerName: _ownerName.text.trim(),
            // Validated by _validPhone, so normalization cannot fail here.
            phone: normalizeEthiopianPhone(_phone.text)!,
            password: _password.text,
            ownerPin: _pin.text,
            shopType: _shopType,
            locale: locale,
          );
      router.go('/pos');
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(localizedErrorMessage(l, e))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _ShopTypeSelector extends StatelessWidget {
  const _ShopTypeSelector({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Row(
      children: [
        Expanded(
          child: _TypeCard(
            icon: Icons.storefront_rounded,
            label: l.registerTypeRegularLabel,
            description: l.registerTypeRegularDesc,
            selected: value == 'regular',
            onTap: () => onChanged('regular'),
          ),
        ),
        const SizedBox(width: SuuqSpacing.sm),
        Expanded(
          child: _TypeCard(
            icon: Icons.bakery_dining_rounded,
            label: l.registerTypeBakeryLabel,
            description: l.registerTypeBakeryDesc,
            selected: value == 'bakery',
            onTap: () => onChanged('bakery'),
          ),
        ),
      ],
    );
  }
}

class _TypeCard extends StatelessWidget {
  const _TypeCard({
    required this.icon,
    required this.label,
    required this.description,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(SuuqSpacing.sm),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(SuuqRadius.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              icon,
              size: 28,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(height: SuuqSpacing.xs),
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: selected ? scheme.primary : scheme.onSurface,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              description,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: 4,
            bottom: SuuqSpacing.xs,
          ),
          child: Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  letterSpacing: 1.2,
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ),
        ...children,
      ],
    );
  }
}
