import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/features/auth/data/auth_remote_data_source.dart';
import 'package:suuqii/features/auth/presentation/providers.dart';
import 'package:suuqii/shared/widgets/sheet_handle.dart';

/// Bottom sheet that prompts for the owner PIN, calls the backend, and
/// returns the challenge token. Returns null on cancel or wrong PIN.
///
/// Sensitive ops on the API require `X-Owner-Challenge: <token>` (or the
/// token inside the sync event payload). A challenge is single-use, so a
/// flow that queues two sensitive events has to ask twice; pass [step] and
/// [steps] then, and the sheet says which approval this is.
Future<String?> requestOwnerChallenge(
  BuildContext context,
  WidgetRef ref, {
  int? step,
  int steps = 1,
}) async {
  return showModalBottomSheet<String?>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _OwnerPinSheet(step: step, steps: steps),
  );
}

class _OwnerPinSheet extends ConsumerStatefulWidget {
  const _OwnerPinSheet({required this.step, required this.steps});

  /// 1-based position in a multi-approval flow, or null for a single one.
  final int? step;
  final int steps;

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
    // SuuqSheet scrolls under the keyboard, so "Authorize" stays reachable
    // on a small phone; the keyboard's done key submits as well.
    return SuuqSheet(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.l10n.ownerPinRequired,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(context.l10n.ownerPinExplain),
          if (widget.step != null) ...[
            const SizedBox(height: 4),
            Text(
              context.l10n.ownerPinStepOf(widget.step!, widget.steps),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 20),
          TextField(
            controller: _pin,
            keyboardType: TextInputType.number,
            obscureText: true,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: 8,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) {
              if (!_busy) _submit();
            },
            style: const TextStyle(fontSize: 24, letterSpacing: 6),
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              labelText: context.l10n.ownerPinLabel,
              errorText: _error,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: Text(context.l10n.ownerPinAuthorize),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final l = context.l10n;
    final pin = _pin.text.trim();
    if (pin.length < 4) {
      setState(() => _error = l.ownerPinEnterDigits);
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
          _error = l.errNetwork;
        });
      }
    }
  }
}
