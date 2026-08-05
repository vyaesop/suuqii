import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/http/dio_client.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/shared/widgets/section_card.dart';

/// Owner-only data export.
///
/// A shop that came from a spreadsheet needs to be able to get its data back
/// out; an app you cannot export from reads as a trap however good it is. The
/// files are plain CSV because the audience opens them in Google Sheets.
///
/// Import is deliberately server-side only for now (`POST
/// /v1/export/products/import`): it is a one-off migration step done with a
/// laptop when a shop is onboarded, not something an owner does on a phone.
class DataScreen extends ConsumerStatefulWidget {
  const DataScreen({super.key});

  @override
  ConsumerState<DataScreen> createState() => _DataScreenState();
}

class _DataScreenState extends ConsumerState<DataScreen> {
  String? _busyPath;

  Future<void> _export(String path, String filename) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busyPath = path);
    try {
      final dio = ref.read(dioProvider);
      final res = await dio.get<List<int>>(
        path,
        options: Options(responseType: ResponseType.bytes),
      );
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().toIso8601String().split('T').first;
      final file = File(p.join(dir.path, '$filename-$stamp.csv'));
      await file.writeAsBytes(res.data ?? const []);
      await Share.shareXFiles([XFile(file.path, mimeType: 'text/csv')]);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(localizedErrorMessage(l, e))),
      );
    } finally {
      if (mounted) setState(() => _busyPath = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.dataTitle)),
      body: ListView(
        padding: const EdgeInsets.all(SuuqSpacing.md),
        children: [
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.receipt_long_outlined),
                  title: Text(l.dataExportSales),
                  subtitle: Text(l.dataExportHint),
                  trailing: _busyPath == _salesPath
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.ios_share_rounded),
                  enabled: _busyPath == null,
                  onTap: _busyPath != null
                      ? null
                      : () => _export(_salesPath, 'sales'),
                ),
                const Divider(height: 1),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.inventory_2_outlined),
                  title: Text(l.dataExportProducts),
                  subtitle: Text(l.dataExportHint),
                  trailing: _busyPath == _productsPath
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.ios_share_rounded),
                  enabled: _busyPath == null,
                  onTap: _busyPath != null
                      ? null
                      : () => _export(_productsPath, 'products'),
                ),
              ],
            ),
          ),
          const SizedBox(height: SuuqSpacing.md),
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.dataImportProducts, style: theme.textTheme.titleMedium),
                const SizedBox(height: SuuqSpacing.xs),
                Text(l.dataImportHint, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static const _salesPath = '/v1/export/sales.csv?range=365d';
  static const _productsPath = '/v1/export/products.csv';
}
