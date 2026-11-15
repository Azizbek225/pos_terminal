import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants.dart';
import '../../../core/currency.dart';
import '../../../core/formatters.dart';
import '../../../core/theme.dart';
import '../../../data/database.dart';
import '../../../state/cart.dart';
import '../../../state/providers.dart';
import '../../customers/customer_widgets.dart';

class PaymentResult {
  PaymentResult(this.payment, this.print);
  final PaymentInput payment;
  final bool print;
}

/// To'lov oynasi: naqd, karta, o'tkazma, aralash yoki nasiya; qaytim hisoblash.
Future<PaymentResult?> showPaymentDialog(BuildContext context, {required int total, bool printDefault = true}) {
  return showDialog<PaymentResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PaymentDialog(total: total, printDefault: printDefault),
  );
}

class _PaymentDialog extends ConsumerStatefulWidget {
  const _PaymentDialog({required this.total, required this.printDefault});
  final int total;
  final bool printDefault;

  @override
  ConsumerState<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends ConsumerState<_PaymentDialog> {
  PaymentType _type = PaymentType.cash;
  final _cash = TextEditingController();
  final _card = TextEditingController();
  final _transfer = TextEditingController();
  final _usd = TextEditingController();
  late bool _print = widget.printDefault;

  /// Naqd rejimda dollar maydoni ochiqmi.
  bool _withUsd = false;
  Customer? _customer;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cash.text = '${widget.total}';
  }

  @override
  void dispose() {
    _cash.dispose();
    _card.dispose();
    _transfer.dispose();
    _usd.dispose();
    super.dispose();
  }

  int _v(TextEditingController c) => (Fmt.parseNum(c.text) ?? 0).round();

  int get _rate => ref.read(usdRateProvider);

  /// Mijoz bergan dollar (naqd va aralash rejimda).
  double get _usdValue {
    if (_rate <= 0) return 0;
    if (_type == PaymentType.mixed || (_type == PaymentType.cash && _withUsd)) {
      final v = Fmt.parseNum(_usd.text) ?? 0;
      return v < 0 ? 0 : v;
    }
    return 0;
  }

  PaymentInput get _input => switch (_type) {
        PaymentType.cash => PaymentInput(cash: _v(_cash), usd: _usdValue, usdRate: _rate),
        PaymentType.card => PaymentInput(card: widget.total, usdRate: _rate),
        PaymentType.transfer => PaymentInput(transfer: widget.total, usdRate: _rate),
        PaymentType.mixed => PaymentInput(
            cash: _v(_cash), card: _v(_card), transfer: _v(_transfer), usd: _usdValue, usdRate: _rate),
        PaymentType.debt => PaymentInput(
            cash: _v(_cash),
            card: _v(_card),
            debt: (widget.total - _v(_cash) - _v(_card)).clamp(0, widget.total),
            customerId: _customer?.id ?? '',
            customerName: _customer?.name ?? '',
            usdRate: _rate,
          ),
      };

  /// Naqd rejimda dollar kiritilsa — so'm qismi qolgan summaga tushadi.
  void _onUsdChanged() {
    setState(() {
      _error = null;
      if (_type == PaymentType.cash) {
        final rest = widget.total - PaymentInput(usd: _usdValue, usdRate: _rate).usdInSum;
        _cash.text = rest > 0 ? '$rest' : '0';
      }
    });
  }

  int get _change => (_input.covered - widget.total).clamp(0, 1 << 40);
  int get _remaining => (widget.total - _input.covered).clamp(0, 1 << 40);

  void _setType(PaymentType t) {
    setState(() {
      _type = t;
      _error = null;
      if (t == PaymentType.cash) {
        _cash.text = '${widget.total}';
        _usd.text = '';
        _withUsd = false;
      }
      if (t == PaymentType.mixed || t == PaymentType.debt) {
        _cash.text = '';
        _card.text = '';
        _transfer.text = '';
        _usd.text = '';
      }
    });
  }

  /// Tez naqd tugmalari: aniq summa va yuqoriga yaxlitlangan banknotlar.
  List<int> get _quickCash {
    final t = widget.total;
    final set = <int>{t};
    for (final step in [1000, 5000, 10000, 50000, 100000, 200000]) {
      final up = ((t + step - 1) ~/ step) * step;
      if (up > t) set.add(up);
    }
    final list = set.toList()..sort();
    return list.take(6).toList();
  }

  void _confirm() {
    final p = _input;
    if (_type == PaymentType.debt && _customer == null) {
      setState(() => _error = 'Nasiya uchun mijozni tanlang yoki yangisini qo\'shing');
      return;
    }
    if (p.card + p.transfer > widget.total) {
      setState(() => _error = "Karta va o'tkazma summasi chekdan oshmasligi kerak");
      return;
    }
    if (p.covered < widget.total) {
      setState(() => _error = "To'lov yetarli emas — yana ${Fmt.money(_remaining)} kerak");
      return;
    }
    Navigator.pop(context, PaymentResult(p, _print));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget field(TextEditingController c, String label, IconData icon, {bool autofocus = false}) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(
            controller: c,
            autofocus: autofocus,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]'))],
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon), suffixText: "so'm"),
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _confirm(),
          ),
        );
    final rate = ref.watch(usdRateProvider);
    Widget usdField({bool autofocus = false}) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(
            controller: _usd,
            autofocus: autofocus,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9., ]'))],
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            decoration: InputDecoration(
              labelText: 'Dollar (naqd)',
              prefixIcon: const Icon(Icons.attach_money),
              suffixText: r'$',
              helperText: _usdValue > 0
                  ? "= ${Fmt.money(PaymentInput(usd: _usdValue, usdRate: rate).usdInSum)} (kurs ${Fmt.money(rate, suffix: false)})"
                  : 'Kurs: 1\$ = ${Fmt.money(rate)}',
            ),
            onChanged: (_) => _onUsdChanged(),
            onSubmitted: (_) => _confirm(),
          ),
        );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f1): () => _setType(PaymentType.cash),
        const SingleActivator(LogicalKeyboardKey.f2): () => _setType(PaymentType.card),
        const SingleActivator(LogicalKeyboardKey.f3): () => _setType(PaymentType.transfer),
        const SingleActivator(LogicalKeyboardKey.f4): () => _setType(PaymentType.mixed),
        const SingleActivator(LogicalKeyboardKey.f5): () => _setType(PaymentType.debt),
      },
      child: AlertDialog(
        title: const Text("To'lov"),
        content: SizedBox(
          width: 540,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(children: [
                  const Text("To'lanadigan summa"),
                  Text(Fmt.money(widget.total),
                      style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
                  if (rate > 0) Text('≈ ${Money.usd(widget.total / rate)}  (1\$ = ${Fmt.money(rate)})'),
                ]),
              ),
              const SizedBox(height: 16),
              SegmentedButton<PaymentType>(
                showSelectedIcon: false,
                // Tor ekranda (telefon) ikonkalar yashiriladi — yozuvlar sig'ishi uchun.
                segments: [
                  for (final (t, label, icon) in const [
                    (PaymentType.cash, 'Naqd', Icons.payments),
                    (PaymentType.card, 'Karta', Icons.credit_card),
                    (PaymentType.transfer, "O'tkazma", Icons.swap_horiz),
                    (PaymentType.mixed, 'Aralash', Icons.call_split),
                    (PaymentType.debt, 'Nasiya', Icons.menu_book_outlined),
                  ])
                    ButtonSegment(
                      value: t,
                      label: Text(label, maxLines: 1, softWrap: false),
                      icon: MediaQuery.sizeOf(context).width >= 700 ? Icon(icon) : null,
                    ),
                ],
                selected: {_type},
                onSelectionChanged: (s) => _setType(s.first),
              ),
              const SizedBox(height: 16),
              if (_type == PaymentType.cash) ...[
                if (_withUsd) usdField(autofocus: true),
                field(_cash, _withUsd ? "Qolgani so'mda" : 'Mijoz bergan naqd pul', Icons.payments, autofocus: !_withUsd),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final q in _quickCash)
                    ActionChip(
                      label: Text(Fmt.money(q, suffix: false)),
                      onPressed: () => setState(() => _cash.text = '$q'),
                    ),
                  if (rate > 0 && !_withUsd)
                    ActionChip(
                      avatar: const Icon(Icons.attach_money, size: 18),
                      label: const Text('Dollar bilan'),
                      onPressed: () => setState(() {
                        _withUsd = true;
                        _usd.text = '';
                      }),
                    ),
                ]),
              ],
              if (_type == PaymentType.card)
                const ListTile(
                  leading: Icon(Icons.credit_card),
                  title: Text("To'liq summa karta (terminal) orqali"),
                  subtitle: Text('Humo / Uzcard / Visa — terminalda tasdiqlangach "Tasdiqlash" ni bosing'),
                ),
              if (_type == PaymentType.transfer)
                const ListTile(
                  leading: Icon(Icons.swap_horiz),
                  title: Text("To'liq summa o'tkazma orqali"),
                  subtitle: Text("Click / Payme / bank o'tkazmasi tushganini tekshiring"),
                ),
              if (_type == PaymentType.mixed) ...[
                field(_cash, "Naqd (so'm)", Icons.payments, autofocus: true),
                if (rate > 0) usdField(),
                field(_card, 'Karta', Icons.credit_card),
                field(_transfer, "O'tkazma", Icons.swap_horiz),
                Text('Qolgan: ${Fmt.money(_remaining)}',
                    style: TextStyle(
                        color: _remaining > 0 ? theme.colorScheme.error : AppTheme.success(context),
                        fontWeight: FontWeight.bold)),
              ],
              if (_type == PaymentType.debt) ...[
                CustomerPicker(selected: _customer, onChanged: (c) => setState(() {
                  _customer = c;
                  _error = null;
                })),
                const SizedBox(height: 12),
                field(_cash, 'Hozir naqd to\'laydi', Icons.payments),
                field(_card, 'Hozir karta bilan to\'laydi', Icons.credit_card),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(children: [
                    Icon(Icons.menu_book_outlined, color: theme.colorScheme.error),
                    const SizedBox(width: 8),
                    const Text('Qarzga yoziladi:', style: TextStyle(fontSize: 18)),
                    const Spacer(),
                    Text(Fmt.money(_input.debt),
                        style: theme.textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.error)),
                  ]),
                ),
                if (_customer?.currency == Currency.usd.code)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      rate > 0
                          ? "Mijoz qarzi dollarda: ${Money.usd(Money.sumToCents(_input.debt, rate) / 100)} yoziladi (kurs ${Fmt.money(rate, suffix: false)})"
                          : 'Mijoz qarzi dollarda — avval dollar kursini kiriting',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
              ],
              const SizedBox(height: 12),
              if (_change > 0)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.success(context).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(children: [
                    Icon(Icons.change_circle, color: AppTheme.success(context)),
                    const SizedBox(width: 8),
                    const Text('Qaytim:', style: TextStyle(fontSize: 18)),
                    const Spacer(),
                    Text(Fmt.money(_change),
                        style: theme.textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.bold, color: AppTheme.success(context))),
                  ]),
                ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _print,
                onChanged: (v) => setState(() => _print = v ?? true),
                title: const Text('Chek chop etish'),
              ),
              if (_error != null) Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Bekor qilish (Esc)')),
          FilledButton.icon(
            onPressed: _confirm,
            icon: const Icon(Icons.check),
            label: const Text('Tasdiqlash (Enter)'),
          ),
        ],
      ),
    );
  }
}
