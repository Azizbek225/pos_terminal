import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Xatoni `<appSupport>/startup_error.log` fayliga yozish (yordam so'rash uchun).
Future<String?> writeStartupLog(Object error, StackTrace stack) async {
  try {
    final dir = await getApplicationSupportDirectory();
    final f = File('${dir.path}${Platform.pathSeparator}startup_error.log');
    await f.writeAsString('${DateTime.now()}\n$error\n$stack\n\n', mode: FileMode.append, flush: true);
    return f.path;
  } catch (_) {
    return null;
  }
}

/// Ilova ishga tusha olmaganda ko'rsatiladigan oyna: xato matni va uni
/// nusxalash tugmasi. Ma'lumotlar bazasi o'chirilmaydi.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.error, required this.stack, this.logPath});
  final Object error;
  final StackTrace stack;
  final String? logPath;

  @override
  Widget build(BuildContext context) {
    final text = '$error\n\n$stack';
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'POS Terminal',
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.error_outline, color: Colors.red, size: 32),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text('Dastur ishga tushmadi', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text("Ma'lumotlaringiz o'chirilmagan. Quyidagi xato matnini nusxalab, yordam uchun yuboring."),
                if (logPath != null) ...[
                  const SizedBox(height: 4),
                  SelectableText('Fayl: $logPath', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                ],
                const SizedBox(height: 12),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Builder(
                  builder: (context) => FilledButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: text));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nusxalandi')));
                      }
                    },
                    icon: const Icon(Icons.copy),
                    label: const Text('Xatoni nusxalash'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
