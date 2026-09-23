// Abstraction over the native file picker for product images (Phase 5 UI
// refinement).
//
// Real desktop implementation uses `file_picker` (Windows open dialog).
// Tests inject a fake so no real dialog ever opens. Cancel returns null
// (not an error). Paths are re-validated against the backend allowlist
// (.png/.jpg/.jpeg/.webp/.bmp) even if the dialog filter is bypassed.
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const List<String> kAllowedProductImageExtensions = [
  '.png',
  '.jpg',
  '.jpeg',
  '.webp',
  '.bmp',
];

abstract class ProductImagePickerService {
  /// Opens the native image picker. Returns the absolute path of the chosen
  /// file, or null if the user cancelled or picked an unsupported file.
  Future<String?> pickImage();

  bool isSupportedPath(String path);
}

class FilePickerProductImageService implements ProductImagePickerService {
  const FilePickerProductImageService();

  @override
  Future<String?> pickImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'bmp'],
      allowMultiple: false,
      dialogTitle: 'Choose product image',
    );
    // User cancelled → not an error.
    if (result == null || result.files.isEmpty) return null;
    final path = result.files.single.path;
    if (path == null || path.trim().isEmpty) return null;
    // Defense in depth: re-validate extension even if the OS filter was
    // bypassed (or "All files" was selected on some platforms).
    if (!isSupportedPath(path)) return null;
    return path;
  }

  @override
  bool isSupportedPath(String path) {
    final lower = path.toLowerCase();
    return kAllowedProductImageExtensions.any(lower.endsWith);
  }
}

final productImagePickerProvider = Provider<ProductImagePickerService>((ref) {
  return const FilePickerProductImageService();
});
