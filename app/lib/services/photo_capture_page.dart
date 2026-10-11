import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// Kompyuter (Windows) web-kamerasi orqali surat olish sahifasi.
/// Telefonda bu sahifa ishlatilmaydi — u yerda tizim kamerasi ochiladi.
/// Qaytaradi: olingan surat yoki null (bekor qilindi).
Future<XFile?> capturePhotoWithWebcam(BuildContext context) {
  return Navigator.of(context).push<XFile>(
    MaterialPageRoute(fullscreenDialog: true, builder: (_) => const _PhotoCapturePage()),
  );
}

class _PhotoCapturePage extends StatefulWidget {
  const _PhotoCapturePage();

  @override
  State<_PhotoCapturePage> createState() => _PhotoCapturePageState();
}

class _PhotoCapturePageState extends State<_PhotoCapturePage> {
  List<CameraDescription> _cameras = const [];
  int _index = 0;
  CameraController? _controller;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() => _error = 'Kamera topilmadi. Web-kamerani ulang.');
        return;
      }
      await _open(0);
    } catch (e) {
      if (mounted) setState(() => _error = 'Kamerani ochib bo\'lmadi: $e');
    }
  }

  Future<void> _open(int index) async {
    final old = _controller;
    setState(() {
      _controller = null;
      _index = index;
    });
    await old?.dispose();
    final c = CameraController(_cameras[index], ResolutionPreset.high, enableAudio: false);
    try {
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _controller = c;
        _error = null;
      });
    } catch (e) {
      await c.dispose();
      if (mounted) setState(() => _error = 'Kamerani ochib bo\'lmadi: $e');
    }
  }

  Future<void> _take() async {
    final c = _controller;
    if (c == null || _busy) return;
    setState(() => _busy = true);
    try {
      final file = await c.takePicture();
      if (mounted) Navigator.pop(context, file);
    } catch (e) {
      if (mounted) setState(() => _error = 'Surat olinmadi: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Tovarni suratga olish'),
        actions: [
          if (_cameras.length > 1)
            IconButton(
              tooltip: 'Boshqa kamera',
              icon: const Icon(Icons.cameraswitch_outlined),
              onPressed: () => _open((_index + 1) % _cameras.length),
            ),
        ],
      ),
      body: Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
              )
            : c == null
                ? const CircularProgressIndicator()
                : AspectRatio(aspectRatio: c.value.aspectRatio, child: CameraPreview(c)),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: c == null
          ? null
          : FloatingActionButton.large(
              onPressed: _busy ? null : _take,
              tooltip: 'Suratga olish',
              child: _busy ? const CircularProgressIndicator() : const Icon(Icons.photo_camera),
            ),
    );
  }
}
