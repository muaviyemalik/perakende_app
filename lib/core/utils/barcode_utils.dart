import 'package:flutter/services.dart';

class BarcodeUtils {
  /// Checks if the given barcode string contains only digits.
  static bool isValidBarcode(String barcode) {
    if (barcode.isEmpty) return false;
    return RegExp(r'^[0-9]+$').hasMatch(barcode);
  }

  /// Formatter to restrict text input to only digits for barcodes.
  static List<TextInputFormatter> get barcodeInputFormatters {
    return [
      FilteringTextInputFormatter.digitsOnly,
    ];
  }
}
