import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/product_images.dart';

/// Imzo qo'yish sahifasi: agent barmog'i (yoki stilus, sichqoncha) bilan
/// ekranga imzo chizadi. Qaytaradi: saqlangan PNG fayl nomi yoki null.
Future<String?> openSignaturePad(BuildContext context, {String title = 'Agent imzosi', String? subtitle}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _SignaturePage(title: title, subtitle: subtitle),
    ),
  );
}

class _SignaturePage extends StatefulWidget {
  const _SignaturePage({required this.title, this.subtitle});
  final String title;
  final String? subtitle;

  @override
  State<_SignaturePage> createState() => _SignaturePageState();
}

class _SignaturePageState extends State<_SignaturePage> {
  final _strokes = <List<Offset>>[];
  Size _size = Size.zero;
  bool _saving = false;

  bool get _empty => _strokes.every((s) => s.length < 2);

  Future<void> _save() async {
    if (_empty || _saving) return;
    setState(() => _saving = true);
    try {
      final bytes = await renderSignaturePng(_strokes, _size);
      final name = await ProductImages.saveBytes(bytes);
      if (mounted) Navigator.pop(context, name);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Imzo saqlanmadi: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          TextButton.icon(
            onPressed: _strokes.isEmpty ? null : () => setState(_strokes.clear),
            icon: const Icon(Icons.refresh),
            label: const Text('Tozalash'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.subtitle != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(widget.subtitle!, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: theme.colorScheme.outline),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: LayoutBuilder(
                    builder: (context, c) {
                      _size = Size(c.maxWidth, c.maxHeight);
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (d) {
                          HapticFeedback.selectionClick();
                          setState(() => _strokes.add([d.localPosition]));
                        },
                        onPanUpdate: (d) => setState(() => _strokes.last.add(d.localPosition)),
                        child: CustomPaint(
                          painter: _SignaturePainter(_strokes),
                          child: _strokes.isEmpty
                              ? Center(
                                  child: Text(
                                    'Shu yerga imzo qo\'ying',
                                    style: theme.textTheme.titleLarge?.copyWith(color: Colors.black26),
                                  ),
                                )
                              : const SizedBox.expand(),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: _empty || _saving ? null : _save,
                icon: const Icon(Icons.check),
                label: const Text('Imzoni tasdiqlash'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SignaturePainter extends CustomPainter {
  _SignaturePainter(this.strokes);
  final List<List<Offset>> strokes;

  static void paintStrokes(Canvas canvas, List<List<Offset>> strokes) {
    final paint = Paint()
      ..color = const Color(0xFF0D1B4C)
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (final s in strokes) {
      if (s.length == 1) {
        canvas.drawCircle(s.first, 1.6, paint..style = PaintingStyle.fill);
        paint.style = PaintingStyle.stroke;
        continue;
      }
      final path = Path()..moveTo(s.first.dx, s.first.dy);
      for (var i = 1; i < s.length; i++) {
        // Silliq chiziq: nuqtalar o'rtasidan kvadratik egri.
        final mid = Offset((s[i - 1].dx + s[i].dx) / 2, (s[i - 1].dy + s[i].dy) / 2);
        path.quadraticBezierTo(s[i - 1].dx, s[i - 1].dy, mid.dx, mid.dy);
      }
      path.lineTo(s.last.dx, s.last.dy);
      canvas.drawPath(path, paint);
    }
  }

  @override
  void paint(Canvas canvas, Size size) => paintStrokes(canvas, strokes);

  @override
  bool shouldRepaint(_SignaturePainter old) => true;
}

/// Imzo chiziqlarini oq fonli PNG ga aylantiradi (chegaralar bo'yicha kesilgan).
Future<List<int>> renderSignaturePng(List<List<Offset>> strokes, Size area) async {
  final points = strokes.expand((s) => s);
  var minX = area.width, minY = area.height, maxX = 0.0, maxY = 0.0;
  for (final p in points) {
    if (p.dx < minX) minX = p.dx;
    if (p.dy < minY) minY = p.dy;
    if (p.dx > maxX) maxX = p.dx;
    if (p.dy > maxY) maxY = p.dy;
  }
  const pad = 16.0;
  final rect = Rect.fromLTRB(minX - pad, minY - pad, maxX + pad, maxY + pad);
  final w = rect.width.clamp(40, 2000).toDouble();
  final h = rect.height.clamp(40, 1000).toDouble();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);
  canvas.translate(-rect.left, -rect.top);
  _SignaturePainter.paintStrokes(canvas, strokes);
  final image = await recorder.endRecording().toImage(w.ceil(), h.ceil());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}
