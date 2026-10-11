import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Kamera orqali skanerlash faqat telefon/planshet va macOS da mavjud.
bool get cameraScanSupported =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

/// Kamera skaneri sahifasini ochadi va topilgan kodni qaytaradi.
Future<String?> scanWithCamera(BuildContext context) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute(fullscreenDialog: true, builder: (_) => const _CameraScannerPage()),
  );
}

class _CameraScannerPage extends StatefulWidget {
  const _CameraScannerPage();

  @override
  State<_CameraScannerPage> createState() => _CameraScannerPageState();
}

class _CameraScannerPageState extends State<_CameraScannerPage> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
      BarcodeFormat.code128,
      BarcodeFormat.code39,
      BarcodeFormat.qrCode,
    ],
  );
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final v = b.rawValue;
      if (v != null && v.isNotEmpty) {
        _done = true;
        Navigator.of(context).pop(v);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shtrix-kodni skanerlash'),
        actions: [
          IconButton(
            tooltip: 'Chiroq',
            icon: const Icon(Icons.flash_on),
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            tooltip: 'Kamerani almashtirish',
            icon: const Icon(Icons.cameraswitch),
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          IgnorePointer(
            child: Container(
              width: 280,
              height: 160,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.greenAccent, width: 3),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const Positioned(
            bottom: 40,
            child: Text(
              'Shtrix-kodni ramka ichiga joylashtiring',
              style: TextStyle(color: Colors.white, fontSize: 16, shadows: [Shadow(blurRadius: 4)]),
            ),
          ),
        ],
      ),
    );
  }
}
