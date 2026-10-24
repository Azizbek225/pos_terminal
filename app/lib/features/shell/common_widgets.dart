import 'package:flutter/material.dart';

import '../../services/product_images.dart';

/// Umumiy kichik vidjetlar va dialog yordamchilari.

/// Xabarlar kassadagi "To'lov" tugmasini yopib qo'ymasligi uchun:
/// keng ekranda — o'ng paneldagi pastki burchakda, telefonda — ekran tepasida.
EdgeInsets snackMargin(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  if (size.width >= 900) return EdgeInsets.only(left: size.width * 0.63 + 16, right: 16, bottom: 16);
  // Pastki navigatsiya (~80) va xabarning o'zi (~100) uchun joy qoldiriladi.
  final top = MediaQuery.paddingOf(context).top;
  return EdgeInsets.only(left: 12, right: 12, bottom: (size.height - top - 340).clamp(16, double.infinity));
}

void showMessage(BuildContext context, String text, {bool error = false}) {
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(text),
      margin: snackMargin(context),
      backgroundColor: error ? scheme.error : null,
      duration: Duration(seconds: error ? 5 : 3),
    ));
}

Future<bool> confirmDialog(BuildContext context, String title, String message,
    {String ok = 'Ha', String cancel = 'Bekor qilish', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(cancel)),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error) : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// Kichik ko'rsatkich kartasi (dashboard va yuqori panel).
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.color,
    this.subtitle,
    this.onTap,
    this.compact = false,
  });

  final String label;
  final String value;
  final IconData? icon;
  final Color? color;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.primary;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 16, vertical: compact ? 8 : 14),
          child: Row(
            children: [
              if (icon != null) ...[
                Container(
                  padding: EdgeInsets.all(compact ? 6 : 10),
                  decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                  child: Icon(icon, color: c, size: compact ? 20 : 24),
                ),
                SizedBox(width: compact ? 10 : 14),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(value,
                          style: (compact ? theme.textTheme.titleMedium : theme.textTheme.titleLarge)
                              ?.copyWith(fontWeight: FontWeight.bold)),
                    ),
                    if (subtitle != null)
                      Text(subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sarlavhali bo'lim kartasi.
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, required this.child, this.trailing, this.padding = 16});

  final String title;
  final Widget child;
  final Widget? trailing;
  final double padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(padding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Expanded(
                child: Text(title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              ),
              ?trailing,
            ]),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 48, color: c.withValues(alpha: 0.5)),
          const SizedBox(height: 8),
          Text(text, textAlign: TextAlign.center, style: TextStyle(color: c)),
        ]),
      ),
    );
  }
}

/// Raqam kiritish dialogi (miqdor, summa).
Future<double?> askNumber(BuildContext context,
    {required String title, double? initial, String? suffix, bool decimal = true}) async {
  final ctrl = TextEditingController(text: initial == null ? '' : _trim(initial));
  final r = await showDialog<double>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        keyboardType: TextInputType.numberWithOptions(decimal: decimal),
        decoration: InputDecoration(suffixText: suffix),
        onSubmitted: (v) => Navigator.pop(c, double.tryParse(v.replaceAll(' ', '').replaceAll(',', '.'))),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Bekor qilish')),
        FilledButton(
          onPressed: () => Navigator.pop(c, double.tryParse(ctrl.text.replaceAll(' ', '').replaceAll(',', '.'))),
          child: const Text('OK'),
        ),
      ],
    ),
  );
  ctrl.dispose();
  return r;
}

String _trim(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// Tovar rasmi (kichik ko'rinish). Rasm bo'lmasa — [fallback] yoki oddiy belgi.
class ProductThumb extends StatelessWidget {
  const ProductThumb({super.key, required this.imagePath, this.size = 40, this.fallback, this.radius = 8});
  final String imagePath;
  final double size;
  final double radius;
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    final image = ProductImages.provider(imagePath);
    final theme = Theme.of(context);
    if (image == null) {
      return fallback ??
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(radius),
            ),
            child: Icon(Icons.image_outlined, size: size * 0.5, color: theme.hintColor),
          );
    }
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image(
        image: ResizeImage(image, width: px, policy: ResizeImagePolicy.fit),
        key: ValueKey(imagePath),
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => SizedBox(width: size, height: size, child: Icon(Icons.broken_image_outlined, color: theme.hintColor)),
      ),
    );
  }
}
