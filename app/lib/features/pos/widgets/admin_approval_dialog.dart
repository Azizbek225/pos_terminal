import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/database.dart';
import '../../../state/providers.dart';

/// Kassir uchun cheklangan amal (masalan 20% dan yuqori chegirma) ni
/// Admin login/paroli bilan tasdiqlash. Muvaffaqiyatli bo'lsa Admin qaytadi.
Future<User?> requestAdminApproval(BuildContext context, WidgetRef ref, {required String reason}) {
  return showDialog<User>(context: context, builder: (_) => _AdminApprovalDialog(reason: reason));
}

class _AdminApprovalDialog extends ConsumerStatefulWidget {
  const _AdminApprovalDialog({required this.reason});
  final String reason;

  @override
  ConsumerState<_AdminApprovalDialog> createState() => _AdminApprovalDialogState();
}

class _AdminApprovalDialogState extends ConsumerState<_AdminApprovalDialog> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final admin = await ref.read(userRepoProvider).verifyAdmin(_user.text, _pass.text);
      if (mounted) Navigator.pop(context, admin);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(children: [Icon(Icons.admin_panel_settings), SizedBox(width: 8), Text('Admin tasdig\'i')]),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.reason),
          const SizedBox(height: 16),
          TextField(
            controller: _user,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Admin login'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _pass,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Parol'),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Bekor qilish')),
        FilledButton(onPressed: _busy ? null : _submit, child: const Text('Tasdiqlash')),
      ],
    );
  }
}
