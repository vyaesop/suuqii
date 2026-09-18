import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/services/cloudinary_service.dart';
import 'package:suuqii/shared/widgets/product_image.dart';

/// Photo picker + upload used by the product form and the style wizard:
/// thumbnail preview, "Upload / Change photo", remove. Owns the upload
/// progress; the caller only receives the final URL (or null on remove).
class ProductPhotoField extends StatefulWidget {
  const ProductPhotoField({
    required this.previewName,
    required this.imageUrl,
    required this.onChanged,
    super.key,
  });

  /// Name whose initial the placeholder badge shows.
  final String previewName;
  final String? imageUrl;
  final ValueChanged<String?> onChanged;

  @override
  State<ProductPhotoField> createState() => _ProductPhotoFieldState();
}

class _ProductPhotoFieldState extends State<ProductPhotoField> {
  bool _uploading = false;
  double _uploadProgress = 0;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: _uploading ? null : _pickAndUpload,
          child: Stack(
            children: [
              ProductImage(
                name: widget.previewName,
                imageUrl: widget.imageUrl,
                size: 84,
              ),
              if (_uploading)
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(SuuqRadius.md),
                    child: ColoredBox(
                      color: Colors.black54,
                      child: Center(
                        child: CircularProgressIndicator(
                          value: _uploadProgress > 0 ? _uploadProgress : null,
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
                onPressed: _uploading ? null : _pickAndUpload,
                icon: const Icon(Icons.upload_rounded, size: 18),
                label: Text(
                  widget.imageUrl == null
                      ? l.productUploadPhoto
                      : l.productChangePhoto,
                ),
              ),
              if (widget.imageUrl != null) ...[
                const SizedBox(height: SuuqSpacing.xs),
                TextButton.icon(
                  onPressed: () => widget.onChanged(null),
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: Text(l.commonRemove),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _pickAndUpload() async {
    final l = context.l10n;
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: Text(ctx.l10n.productTakePhoto),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(ctx.l10n.productChooseFromGallery),
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
    if (picked == null || !mounted) return;

    setState(() {
      _uploading = true;
      _uploadProgress = 0;
    });
    try {
      final url = await CloudinaryService().uploadImage(
        File(picked.path),
        onProgress: (sent, total) {
          if (mounted) setState(() => _uploadProgress = sent / total);
        },
      );
      widget.onChanged(url);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.productUploadFailed(localizedErrorMessage(l, e))),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }
}
