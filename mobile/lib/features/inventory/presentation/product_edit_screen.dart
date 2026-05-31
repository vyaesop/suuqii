import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/services/cloudinary_service.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/inventory/presentation/stock_adjust_sheet.dart';
import 'package:suuqii/shared/widgets/owner_pin_dialog.dart';
import 'package:suuqii/shared/widgets/product_image.dart';

const _units = <String>['piece', 'kg', 'liter', 'pack', 'm'];

class ProductEditScreen extends ConsumerStatefulWidget {
  const ProductEditScreen({super.key, this.productId});
  final String? productId;
  bool get isCreating => productId == null;

  @override
  ConsumerState<ProductEditScreen> createState() => _ProductEditScreenState();
}

class _ProductEditScreenState extends ConsumerState<ProductEditScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _category = TextEditingController();
  final _purchase = TextEditingController();
  final _selling = TextEditingController();
  final _stock = TextEditingController(text: '0');
  final _threshold = TextEditingController(text: '0');
  final _barcode = TextEditingController();
  final _imageUrl = TextEditingController();
  String _unit = 'piece';

  bool _loaded = false;
  bool _busy = false;
  bool _uploading = false;
  double _uploadProgress = 0;
  Decimal? _originalSelling;

  @override
  void initState() {
    super.initState();
    if (widget.isCreating) _loaded = true;
  }

  @override
  void dispose() {
    _name.dispose();
    _category.dispose();
    _purchase.dispose();
    _selling.dispose();
    _stock.dispose();
    _threshold.dispose();
    _barcode.dispose();
    _imageUrl.dispose();
    super.dispose();
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final p = await ref
        .read(productsRepositoryProvider)
        .byId(widget.productId!);
    if (!mounted || p == null) return;
    _name.text = p.name;
    _category.text = p.category ?? '';
    _purchase.text = p.purchasePrice.toString();
    _selling.text = p.sellingPrice.toString();
    _stock.text = p.stock.toString();
    _threshold.text = p.lowStockThreshold.toString();
    _barcode.text = p.barcode ?? '';
    _imageUrl.text = p.imageUrl ?? '';
    _unit = p.unit;
    _originalSelling = p.sellingPrice;
    setState(() => _loaded = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      _ensureLoaded();
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final isOwner = auth is Authenticated && auth.role == 'owner';

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isCreating ? 'New product' : 'Edit product'),
        actions: [
          if (!widget.isCreating)
            TextButton.icon(
              onPressed: () => _showStockSheet(context, isOwner: isOwner),
              icon: const Icon(Icons.tune_rounded, size: 18),
              label: const Text('Adjust stock'),
            ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            SuuqSpacing.lg, SuuqSpacing.sm, SuuqSpacing.lg, 100,
          ),
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Section(
                  title: 'Details',
                  children: [
                    TextFormField(
                      controller: _name,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(labelText: 'Name'),
                      validator: _required,
                    ),
                    const SizedBox(height: SuuqSpacing.sm),
                    TextFormField(
                      controller: _category,
                      decoration: const InputDecoration(
                        labelText: 'Category (optional)',
                      ),
                    ),
                    const SizedBox(height: SuuqSpacing.sm),
                    DropdownButtonFormField<String>(
                      initialValue: _unit,
                      decoration: const InputDecoration(labelText: 'Unit'),
                      items: _units
                          .map(
                            (u) => DropdownMenuItem(
                              value: u,
                              child: Text(u),
                            ),
                          )
                          .toList(),
                      onChanged: (v) =>
                          setState(() => _unit = v ?? 'piece'),
                    ),
                  ],
                ),
                const SizedBox(height: SuuqSpacing.lg),
                _Section(
                  title: 'Pricing',
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _purchase,
                            keyboardType: const TextInputType
                                .numberWithOptions(decimal: true),
                            decoration: const InputDecoration(
                              labelText: 'Purchase',
                              prefixText: 'ETB  ',
                            ),
                            validator: _decimal,
                          ),
                        ),
                        const SizedBox(width: SuuqSpacing.sm),
                        Expanded(
                          child: TextFormField(
                            controller: _selling,
                            keyboardType: const TextInputType
                                .numberWithOptions(decimal: true),
                            decoration: const InputDecoration(
                              labelText: 'Selling',
                              prefixText: 'ETB  ',
                            ),
                            validator: _decimal,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: SuuqSpacing.lg),
                _Section(
                  title: 'Stock',
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _stock,
                            enabled: widget.isCreating,
                            keyboardType: const TextInputType
                                .numberWithOptions(decimal: true),
                            decoration: InputDecoration(
                              labelText: widget.isCreating
                                  ? 'Initial stock'
                                  : 'Current stock',
                              helperText: widget.isCreating
                                  ? null
                                  : 'Use Adjust stock to change',
                            ),
                            validator: _decimal,
                          ),
                        ),
                        const SizedBox(width: SuuqSpacing.sm),
                        Expanded(
                          child: TextFormField(
                            controller: _threshold,
                            keyboardType: const TextInputType
                                .numberWithOptions(decimal: true),
                            decoration: const InputDecoration(
                              labelText: 'Low at',
                              helperText: 'Alert below this',
                            ),
                            validator: _decimal,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: SuuqSpacing.lg),
                _Section(
                  title: 'Image',
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        GestureDetector(
                          onTap: _uploading ? null : _pickAndUploadImage,
                          child: Stack(
                            children: [
                              ProductImage(
                                name: _previewName,
                                imageUrl: _normalizedImageUrl,
                                size: 84,
                              ),
                              if (_uploading)
                                Positioned.fill(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(
                                      SuuqRadius.md,
                                    ),
                                    child: ColoredBox(
                                      color: Colors.black54,
                                      child: Center(
                                        child: CircularProgressIndicator(
                                          value: _uploadProgress > 0
                                              ? _uploadProgress
                                              : null,
                                          color: Colors.white,
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: SuuqSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              OutlinedButton.icon(
                                onPressed:
                                    _uploading ? null : _pickAndUploadImage,
                                icon: const Icon(
                                  Icons.upload_rounded,
                                  size: 18,
                                ),
                                label: Text(
                                  _normalizedImageUrl == null
                                      ? 'Upload photo'
                                      : 'Change photo',
                                ),
                              ),
                              if (_normalizedImageUrl != null) ...[
                                const SizedBox(height: SuuqSpacing.xs),
                                TextButton.icon(
                                  onPressed: () =>
                                      setState(() => _imageUrl.text = ''),
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 16,
                                  ),
                                  label: const Text('Remove'),
                                  style: TextButton.styleFrom(
                                    foregroundColor:
                                        Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: SuuqSpacing.lg),
                _Section(
                  title: 'Identifiers',
                  children: [
                    TextFormField(
                      controller: _barcode,
                      decoration: const InputDecoration(
                        labelText: 'Barcode (optional)',
                        prefixIcon: Icon(
                          Icons.qr_code_scanner_rounded,
                          size: 20,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(SuuqSpacing.md),
          child: FilledButton.icon(
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.check_rounded),
            onPressed: _busy ? null : () => _save(isOwner: isOwner),
            label: Text(widget.isCreating ? 'Create product' : 'Save changes'),
          ),
        ),
      ),
    );
  }

  String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Required' : null;

  String? _decimal(String? v) {
    if (v == null || v.trim().isEmpty) return 'Required';
    final d = Decimal.tryParse(v.trim());
    if (d == null || d < Decimal.zero) return 'Invalid number';
    return null;
  }

  Future<void> _pickAndUploadImage() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final picked = await ImagePicker().pickImage(
      source: source,
      imageQuality: 85,
    );
    if (picked == null) return;

    setState(() {
      _uploading = true;
      _uploadProgress = 0;
    });

    try {
      final url = await CloudinaryService().uploadImage(
        File(picked.path),
        onProgress: (sent, total) =>
            setState(() => _uploadProgress = sent / total),
      );
      setState(() => _imageUrl.text = url);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  String get _previewName {
    final name = _name.text.trim();
    return name.isEmpty ? 'Preview' : name;
  }

  String? get _normalizedImageUrl {
    final value = _imageUrl.text.trim();
    return value.isEmpty ? null : value;
  }

  Future<void> _save({required bool isOwner}) async {
    if (!_form.currentState!.validate()) return;
    final selling = Decimal.parse(_selling.text.trim());
    final purchase = Decimal.parse(_purchase.text.trim());
    final category = _category.text.trim().isEmpty
        ? null
        : _category.text.trim();
    final barcode = _barcode.text.trim().isEmpty ? null : _barcode.text.trim();
    final imageUrl = _normalizedImageUrl;
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);

    final priceChanged =
        _originalSelling != null && _originalSelling != selling;
    String? challenge;
    if (!isOwner && priceChanged) {
      challenge = await requestOwnerChallenge(context, ref);
      if (challenge == null) return;
    }

    setState(() => _busy = true);
    try {
      final repo = ref.read(productsRepositoryProvider);
      if (widget.isCreating) {
        await repo.create(
          name: _name.text.trim(),
          category: category,
          purchasePrice: purchase,
          sellingPrice: selling,
          stock: Decimal.parse(_stock.text.trim()),
          lowStockThreshold: Decimal.parse(_threshold.text.trim()),
          unit: _unit,
          barcode: barcode,
          imageUrl: imageUrl,
          ownerChallengeToken: challenge,
        );
      } else {
        await repo.update(
          id: widget.productId!,
          name: _name.text.trim(),
          category: category,
          purchasePrice: purchase,
          sellingPrice: selling,
          lowStockThreshold: Decimal.parse(_threshold.text.trim()),
          unit: _unit,
          barcode: barcode,
          imageUrl: imageUrl,
          ownerChallengeToken: challenge,
        );
      }
      router.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showStockSheet(
    BuildContext context, {
    required bool isOwner,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await showModalBottomSheet<({Decimal delta, String reason})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const StockAdjustSheet(),
    );
    if (result == null) return;

    String? challenge;
    if (!isOwner) {
      if (!context.mounted) return;
      challenge = await requestOwnerChallenge(context, ref);
      if (challenge == null) return;
    }

    try {
      await ref.read(productsRepositoryProvider).adjustStock(
            productId: widget.productId!,
            delta: result.delta,
            reason: result.reason,
            ownerChallengeToken: challenge,
          );
      messenger.showSnackBar(
        SnackBar(content: Text('Stock adjusted by ${result.delta}')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: SuuqSpacing.xs),
          child: Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  letterSpacing: 1.2,
                ),
          ),
        ),
        ...children,
      ],
    );
  }
}
