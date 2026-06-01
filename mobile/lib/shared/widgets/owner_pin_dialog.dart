import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/features/auth/data/auth_remote_data_source.dart';
import 'package:suuqii/features/auth/presentation/providers.dart';

/// Bottom sheet that prompts for the owner PIN, calls the backend, and
/// returns the challenge token. Returns null on cancel or wrong PIN.
///
/// Sensitive ops on the API require `X-Owner-Challenge: <token>` (or the
/// token inside the sync event payload).
Future<String?> requestOwnerChallenge(
  BuildContext context,
  WidgetRef ref,
) async {
  return showModalBottomSheet<String?>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _OwnerPinSheet(),
  );
}

class _OwnerPinSheet extends ConsumerStatefulWidget {
  const _OwnerPinSheet();

  @override
  ConsumerState<_OwnerPinSheet> createState() => _OwnerPinSheetState();
}

class _OwnerPinSheetState extends ConsumerState<_OwnerPinSheet> {
  final _pin = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Owner PIN required',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text('This action requires the shop owner to authorize.'),
              const SizedBox(height: 20),
              TextField(
                controller: _pin,
                keyboardType: TextInputType.number,
                obscureText: true,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: 8,
                autofocus: true,
                style: const TextStyle(fontSize: 24, letterSpacing: 6),
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                  labelText: 'PIN (4–8 digits)',
                  errorText: _error,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: const Text('Authorize'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final pin = _pin.text.trim();
    if (pin.length < 4) {
      setState(() => _error = 'Enter 4–8 digits');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      final token = await repo.verifyOwnerPin(pin);
      if (mounted) Navigator.pop(context, token);
    } on AuthException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          // Surface the server message directly — it already contains
          // remaining-attempt counts and lockout durations.
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Network error — try again';
        });
      }
    }
  }
}
