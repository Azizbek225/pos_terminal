import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/settings_repository.dart';
import '../../services/scanner/camera_scanner.dart';
import '../../services/sync/sync_service.dart';
import '../../state/providers.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _passFocus = FocusNode();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  /// Telefon hali do'kon serveriga ulanmagan: kirishdan oldin QR orqali ulash
  /// taklif qilinadi (xodimlar, tovarlar serverdan keladi).
  bool _canPair = false;
  String? _pairInfo;

  @override
  void initState() {
    super.initState();
    if (cameraScanSupported) {
      ref.read(settingsRepoProvider).get(SettingKeys.syncUrl).then((url) {
        if (mounted && (url ?? '').trim().isEmpty) setState(() => _canPair = true);
      });
    }
  }

  /// Kompyuterdagi PosServer QR kodi (localhost:8000/ulash) — manzil va kalit o'zi yoziladi.
  Future<void> _pair() async {
    final raw = await scanWithCamera(
      context,
      title: 'Kompyuterga ulash',
      hint: "Kompyuterdagi PosServer QR kodini ko'rsating",
    );
    if (raw == null || !mounted) return;
    final qr = SyncService.parseConnectQr(raw);
    if (qr == null) {
      setState(() => _pairInfo = "Bu PosServer QR kodi emas. Kompyuterda localhost:8000/ulash sahifasini oching.");
      return;
    }
    setState(() {
      _busy = true;
      _pairInfo = 'Server qidirilmoqda...';
    });
    final service = ref.read(syncServiceProvider);
    try {
      final url = await service.firstReachable(qr.urls) ?? qr.urls.first;
      await ref.read(settingsRepoProvider).setAll({
        SettingKeys.syncUrl: url,
        SettingKeys.syncApiKey: qr.key,
        SettingKeys.syncEnabled: '1',
      });
      await service.testConnection();
      await service.start();
      if (mounted) {
        setState(() {
          _canPair = false;
          _pairInfo = "Ulandi. Ma'lumotlar yuklanmoqda — bir oz kutib, do'kondagi login/parol bilan kiring.";
        });
      }
    } catch (e) {
      if (mounted) setState(() => _pairInfo = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _passFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).login(_user.text, _pass.text);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(Icons.point_of_sale_rounded, size: 64, color: theme.colorScheme.primary),
                      const SizedBox(height: 12),
                      Text('POS Terminal',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
                      Text("Xo'jalik mollari do'koni",
                          textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
                      const SizedBox(height: 28),
                      TextField(
                        controller: _user,
                        autofocus: true,
                        autofillHints: const [AutofillHints.username],
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(labelText: 'Login', prefixIcon: Icon(Icons.person)),
                        onSubmitted: (_) => _passFocus.requestFocus(),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _pass,
                        focusNode: _passFocus,
                        obscureText: _obscure,
                        autofillHints: const [AutofillHints.password],
                        decoration: InputDecoration(
                          labelText: 'Parol',
                          prefixIcon: const Icon(Icons.lock),
                          suffixIcon: IconButton(
                            icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                        onSubmitted: (_) => _submit(),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                      ],
                      const SizedBox(height: 22),
                      FilledButton.icon(
                        onPressed: _busy ? null : _submit,
                        icon: _busy
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.login),
                        label: const Text('Kirish'),
                      ),
                      if (_canPair) ...[
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _pair,
                          icon: const Icon(Icons.qr_code_scanner),
                          label: const Text("Do'kon kompyuteriga ulash (QR)"),
                        ),
                      ],
                      if (_pairInfo != null) ...[
                        const SizedBox(height: 8),
                        Text(_pairInfo!, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
                      ],
                      const SizedBox(height: 16),
                      Text(
                        "Birinchi kirish: admin / admin123 — kirgach parolni albatta o'zgartiring.",
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
