import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme.dart';
import 'features/auth/login_page.dart';
import 'features/shell/home_shell.dart';
import 'state/providers.dart';

class PosApp extends ConsumerStatefulWidget {
  const PosApp({super.key});

  @override
  ConsumerState<PosApp> createState() => _PosAppState();
}

class _PosAppState extends ConsumerState<PosApp> {
  @override
  void initState() {
    super.initState();
    // Fon xizmatlari: alert tekshiruvlari va sinxronlash.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(alertServiceProvider).start();
      ref.read(syncServiceProvider).start();
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider);
    return MaterialApp(
      title: 'POS Terminal',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ref.watch(themeModeProvider),
      home: user == null ? const LoginPage() : const HomeShell(),
    );
  }
}
