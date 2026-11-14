import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/currency.dart';
import '../../core/formatters.dart';
import '../../data/database.dart';
import '../../state/providers.dart';
import '../shell/common_widgets.dart';

/// Yangi mijoz qo'shish yoki tahrirlash. Qaytaradi: saqlangan mijoz.
Future<Customer?> showCustomerForm(BuildContext context, WidgetRef ref, {Customer? customer, String name = ''}) {
  return showDialog<Customer>(context: context, builder: (_) => _CustomerForm(customer: customer, initialName: name));
}

class _CustomerForm extends ConsumerStatefulWidget {
  const _CustomerForm({this.customer, this.initialName = ''});
  final Customer? customer;
  final String initialName;

  @override
  ConsumerState<_CustomerForm> createState() => _CustomerFormState();
}

class _CustomerFormState extends ConsumerState<_CustomerForm> {
  late final _name = TextEditingController(text: widget.customer?.name ?? widget.initialName);
  late final _phone = TextEditingController(text: widget.customer?.phone ?? '');
  late final _address = TextEditingController(text: widget.customer?.address ?? '');
  late final _note = TextEditingController(text: widget.customer?.note ?? '');
  late String _currency = widget.customer?.currency ?? Currency.uzs.code;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final c = await ref.read(customerRepoProvider).save(
            id: widget.customer?.id,
            name: _name.text,
            phone: _phone.text,
            address: _address.text,
            note: _note.text,
            currency: _currency,
          );
      if (mounted) Navigator.pop(context, c);
    } catch (e) {
      if (mounted) showMessage(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.customer == null ? 'Yangi mijoz' : 'Mijozni tahrirlash'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Ism familiya', prefixIcon: Icon(Icons.person_outline)),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Telefon', prefixIcon: Icon(Icons.phone_outlined)),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _address,
            decoration: const InputDecoration(labelText: 'Manzil (ixtiyoriy)', prefixIcon: Icon(Icons.home_outlined)),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _note,
            decoration: const InputDecoration(labelText: 'Izoh (ixtiyoriy)', prefixIcon: Icon(Icons.notes)),
          ),
          const SizedBox(height: 12),
          Row(children: [
            const Text('Qarz valyutasi:'),
            const SizedBox(width: 12),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: Currency.uzs.code, label: const Text("So'm")),
                ButtonSegment(value: Currency.usd.code, label: const Text(r'Dollar ($)')),
              ],
              selected: {_currency},
              onSelectionChanged: (v) => setState(() => _currency = v.first),
            ),
          ]),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Bekor qilish')),
        FilledButton(onPressed: _saving ? null : _save, child: const Text('Saqlash')),
      ],
    );
  }
}

/// Mijozni qidirib tanlash (+ yangi mijoz qo'shish).
class CustomerPicker extends ConsumerWidget {
  const CustomerPicker({super.key, required this.selected, required this.onChanged});
  final Customer? selected;
  final ValueChanged<Customer?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(customersProvider).value ?? const <Customer>[];
    if (selected != null) {
      final debt = ref.watch(customerDebtProvider(selected!.id)).value ?? 0;
      return Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: const CircleAvatar(child: Icon(Icons.person)),
          title: Text(selected!.name, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text([
            if (selected!.phone.isNotEmpty) selected!.phone,
            debt > 0 ? 'Hozirgi qarzi: ${Money.fmt(debt, selected!.currency)}' : 'Qarzi yo\'q',
            if (selected!.currency == Currency.usd.code) 'nasiya dollarga yoziladi',
          ].join(' · ')),
          trailing: IconButton(
            tooltip: 'Boshqa mijoz',
            icon: const Icon(Icons.close),
            onPressed: () => onChanged(null),
          ),
        ),
      );
    }
    return Row(children: [
      Expanded(
        child: Autocomplete<Customer>(
          displayStringForOption: (c) => c.phone.isEmpty ? c.name : '${c.name} (${c.phone})',
          optionsBuilder: (v) {
            final q = v.text.trim().toLowerCase();
            if (q.isEmpty) return all.take(20);
            return all.where((c) => c.name.toLowerCase().contains(q) || c.phone.contains(q)).take(20);
          },
          onSelected: onChanged,
          fieldViewBuilder: (context, controller, focus, onSubmit) => TextField(
            controller: controller,
            focusNode: focus,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Mijoz (ism yoki telefon)',
              prefixIcon: Icon(Icons.person_search_outlined),
            ),
            onSubmitted: (_) => onSubmit(),
          ),
        ),
      ),
      const SizedBox(width: 8),
      IconButton.filledTonal(
        tooltip: 'Yangi mijoz',
        icon: const Icon(Icons.person_add_alt_1),
        onPressed: () async {
          final c = await showCustomerForm(context, ref);
          if (c != null) onChanged(c);
        },
      ),
    ]);
  }
}

/// Qarz to'lovi yoki qo'lda qarz yozish oynasi.
Future<void> showCustomerMoneyDialog(BuildContext context, WidgetRef ref, Customer c, {required bool payment}) {
  return showDialog<void>(context: context, builder: (_) => _MoneyDialog(customer: c, payment: payment));
}

class _MoneyDialog extends ConsumerStatefulWidget {
  const _MoneyDialog({required this.customer, required this.payment});
  final Customer customer;
  final bool payment;

  @override
  ConsumerState<_MoneyDialog> createState() => _MoneyDialogState();
}

class _MoneyDialogState extends ConsumerState<_MoneyDialog> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  PaymentType _method = PaymentType.cash;
  bool _saving = false;

  /// Dollar qarzli mijoz so'm bilan to'layapti (kurs bo'yicha dollarga o'tadi).
  bool _paySum = false;

  bool get _usd => widget.customer.currency == Currency.usd.code;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  /// Kiritilgan summa mijoz valyutasida (so'm yoki sent).
  int _minor(int rate) {
    final v = Fmt.parseNum(_amount.text) ?? 0;
    if (!_usd) return v.round();
    if (_paySum) return Money.sumToCents(v.round(), rate);
    return (v * 100).round();
  }

  Future<void> _save() async {
    final rate = ref.read(usdRateProvider);
    if (_usd && _paySum && rate <= 0) {
      showMessage(context, 'Dollar kursi kiritilmagan', error: true);
      return;
    }
    final amount = _minor(rate);
    final cur = widget.customer.currency;
    var note = _note.text.trim();
    if (_usd && _paySum) {
      final sum = (Fmt.parseNum(_amount.text) ?? 0).round();
      note = [Fmt.money(sum), 'kurs ${Fmt.money(rate, suffix: false)}', if (note.isNotEmpty) note].join(', ');
    }
    setState(() => _saving = true);
    try {
      final repo = ref.read(customerRepoProvider);
      final user = ref.read(authProvider);
      if (widget.payment) {
        await repo.addPayment(widget.customer.id, amount,
            method: _method.code, note: note, user: user, usdRate: _usd ? rate : 0);
      } else {
        await repo.addManualDebt(widget.customer.id, amount, note: note, user: user, usdRate: _usd ? rate : 0);
      }
      ref.read(syncServiceProvider).requestSync();
      if (mounted) {
        showMessage(context,
            widget.payment ? "To'lov qabul qilindi: ${Money.fmt(amount, cur)}" : 'Qarz yozildi: ${Money.fmt(amount, cur)}');
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) showMessage(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final debt = ref.watch(customerDebtProvider(widget.customer.id)).value ?? 0;
    final rate = ref.watch(usdRateProvider);
    final cur = widget.customer.currency;
    final inSum = !_usd || _paySum;
    final entered = Fmt.parseNum(_amount.text) ?? 0;
    String? hint;
    if (_usd && rate > 0 && entered > 0) {
      hint = _paySum ? '= ${Money.usd(Money.sumToCents(entered.round(), rate) / 100)} (kurs ${Fmt.money(rate, suffix: false)})'
          : '≈ ${Fmt.money(Money.centsToSum((entered * 100).round(), rate))}';
    }
    return AlertDialog(
      title: Text(widget.payment ? "Qarz to'lovi" : 'Qarz yozish'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.customer.name, style: Theme.of(context).textTheme.titleMedium),
          Text('Hozirgi qarzi: ${Money.fmt(debt, cur)}'
              '${_usd && rate > 0 && debt > 0 ? ' (≈ ${Fmt.money(Money.centsToSum(debt, rate))})' : ''}'),
          if (_usd) ...[
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text(r'Dollarda ($)')),
                ButtonSegment(value: true, label: Text("So'mda (kurs bilan)")),
              ],
              selected: {_paySum},
              onSelectionChanged: (v) => setState(() {
                _paySum = v.first;
                _amount.clear();
              }),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(inSum ? r'[0-9 ]' : r'[0-9., ]'))],
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            decoration: InputDecoration(
              labelText: widget.payment ? "To'lov summasi" : 'Qarz summasi',
              suffixText: inSum ? "so'm" : r'$',
              helperText: hint,
              suffixIcon: widget.payment && debt > 0
                  ? TextButton(
                      onPressed: () => setState(() => _amount.text = !_usd
                          ? '$debt'
                          : _paySum
                              ? '${Money.centsToSum(debt, rate)}'
                              : (debt / 100).toStringAsFixed(2)),
                      child: const Text('Hammasi'))
                  : null,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
          ),
          if (widget.payment) ...[
            const SizedBox(height: 12),
            SegmentedButton<PaymentType>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: PaymentType.cash, label: Text('Naqd')),
                ButtonSegment(value: PaymentType.card, label: Text('Karta')),
                ButtonSegment(value: PaymentType.transfer, label: Text("O'tkazma")),
              ],
              selected: {_method},
              onSelectionChanged: (s) => setState(() => _method = s.first),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            decoration: InputDecoration(
              labelText: 'Izoh (ixtiyoriy)',
              hintText: widget.payment ? null : 'Masalan: daftardagi eski qarz',
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Bekor qilish')),
        FilledButton(onPressed: _saving ? null : _save, child: Text(widget.payment ? 'Qabul qilish' : 'Yozish')),
      ],
    );
  }
}
