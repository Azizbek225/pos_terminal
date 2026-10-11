import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../data/database.dart';
import '../../data/repositories/settings_repository.dart';
import '../../services/scanner/barcode_listener.dart';
import '../../state/cart.dart';
import '../../state/providers.dart';
import '../shell/common_widgets.dart';
import 'widgets/cart_view.dart';
import 'widgets/discount_dialog.dart';
import 'widgets/payment_dialog.dart';
import 'widgets/product_search_field.dart';
import 'widgets/receipt_dialog.dart';
import 'widgets/recommendations_panel.dart';

/// Asosiy savdo oynasi.
///
/// Keng ekran (notebook): chapda ~62% savdo (qidiruv, savat, to'lov),
/// o'ngda ~38% tavsiyalar paneli.
/// Tor ekran (telefon): yorliqlar (Savat / Tez sotiladigan / Mavsumiy) +
/// pastda doimiy "Jami va To'lov" paneli.
///
/// Klaviatura: F2 — qidiruv, F4 — chegirma, F8 — savatni tozalash,
/// F9 — naqd (aniq summa), F12 — to'lov oynasi.
class PosPage extends ConsumerStatefulWidget {
  const PosPage({super.key});

  @override
  ConsumerState<PosPage> createState() => _PosPageState();
}

class _PosPageState extends ConsumerState<PosPage> with SingleTickerProviderStateMixin {
  final _searchKey = GlobalKey<ProductSearchFieldState>();
  final _searchFocus = FocusNode();
  late final TabController _tabs = TabController(length: 3, vsync: this);
  bool _paying = false;

  @override
  void dispose() {
    _searchFocus.dispose();
    _tabs.dispose();
    super.dispose();
  }

  void _add(Product p) {
    ref.read(cartProvider.notifier).add(p);
    SystemSound.play(SystemSoundType.click);
    if (_tabs.index != 0 && MediaQuery.sizeOf(context).width < 900) {
      // Telefonda tavsiyadan qo'shilganda qisqa tasdiq.
      showMessage(context, "${p.name} savatga qo'shildi");
    }
  }

  Future<void> _onScanned(String code) async {
    final ok = await _searchKey.currentState?.handleCode(code);
    if (ok != true) SystemSound.play(SystemSoundType.alert);
  }

  Future<void> _pay({bool quickCash = false}) async {
    if (_paying) return;
    final cart = ref.read(cartProvider);
    if (cart.isEmpty) {
      showMessage(context, "Savat bo'sh");
      return;
    }
    final settings = ref.read(settingsProvider).value ?? const {};
    final autoPrint = (settings[SettingKeys.autoPrint] ?? '1') == '1';

    PaymentResult? result;
    if (quickCash) {
      result = PaymentResult(PaymentInput(cash: cart.total), autoPrint);
    } else {
      result = await showPaymentDialog(context, total: cart.total, printDefault: autoPrint);
    }
    if (result == null || !mounted) return;

    setState(() => _paying = true);
    try {
      final user = ref.read(authProvider)!;
      final sale = await ref.read(checkoutServiceProvider).checkout(cart: cart, payment: result.payment, cashier: user);
      ref.read(cartProvider.notifier).clear();
      ref.read(syncServiceProvider).requestSync();
      if (!mounted) return;

      final change = sale.sale.changeAmount;
      showMessage(
        context,
        'Chek ${sale.sale.receiptNo} saqlandi. Jami: ${Fmt.money(sale.sale.total)}${change > 0 ? ' · Qaytim: ${Fmt.money(change)}' : ''}',
      );
      if (result.print) {
        await printAndReport(context, ref, sale);
      }
    } catch (e) {
      if (mounted) showMessage(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _paying = false);
      _searchFocus.requestFocus();
    }
  }

  Future<void> _reprintLast() async {
    final last = await ref.read(saleRepoProvider).watchLast().first;
    if (last == null || !mounted) return;
    await showReceiptDialog(context, ref, last.id);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return BarcodeKeyboardListener(
      onBarcode: _onScanned,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.f2): () => _searchFocus.requestFocus(),
          const SingleActivator(LogicalKeyboardKey.f4): () => showDiscountDialog(context, ref),
          const SingleActivator(LogicalKeyboardKey.f8): () => ref.read(cartProvider.notifier).clear(),
          const SingleActivator(LogicalKeyboardKey.f9): () => _pay(quickCash: true),
          const SingleActivator(LogicalKeyboardKey.f12): () => _pay(),
        },
        // Fokus qidiruv maydonida (autofocus) — shortcutlar undan yuqoriga ko'tariladi.
        child: Focus(child: wide ? _wide() : _narrow()),
      ),
    );
  }

  Widget _search() => ProductSearchField(key: _searchKey, focusNode: _searchFocus, onPicked: _add);

  Widget _wide() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Chap: savdo oynasi (~62%)
          Expanded(
            flex: 62,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _search(),
                const SizedBox(height: 10),
                const Expanded(child: Card(child: CartView())),
                const SizedBox(height: 10),
                _TotalsBar(
                  onPay: () => _pay(),
                  onQuickCash: () => _pay(quickCash: true),
                  onReprint: _reprintLast,
                  busy: _paying,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // O'ng: tavsiyalar (~38%)
          Expanded(flex: 38, child: RecommendationsPanel(onPick: _add)),
        ],
      ),
    );
  }

  Widget _narrow() {
    final count = ref.watch(cartProvider.select((c) => c.lines.length));
    return Column(
      children: [
        Padding(padding: const EdgeInsets.fromLTRB(8, 8, 8, 0), child: _search()),
        TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: 'Savat ($count)'),
            const Tab(text: 'Tez sotiladigan'),
            const Tab(text: 'Mavsumiy'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              const CartView(),
              Padding(
                padding: const EdgeInsets.all(8),
                child: FrequentSection(onPick: _add),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: SeasonalSection(onPick: _add),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: _TotalsBar(
            onPay: () => _pay(),
            onQuickCash: () => _pay(quickCash: true),
            onReprint: _reprintLast,
            busy: _paying,
            compact: true,
          ),
        ),
      ],
    );
  }
}

/// Jami summa, chegirma va to'lov tugmalari.
class _TotalsBar extends ConsumerWidget {
  const _TotalsBar({
    required this.onPay,
    required this.onQuickCash,
    required this.onReprint,
    required this.busy,
    this.compact = false,
  });

  final VoidCallback onPay;
  final VoidCallback onQuickCash;
  final VoidCallback onReprint;
  final bool busy;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.watch(cartProvider);
    final theme = Theme.of(context);
    final hasDiscount = cart.discountAmount > 0;

    final summary = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Tovarlar: ${Fmt.qty(cart.itemCount)}  ·  Summa: ${Fmt.money(cart.subtotal)}',
          style: theme.textTheme.bodyMedium,
        ),
        if (hasDiscount)
          Text(
            'Chegirma: -${Fmt.money(cart.discountAmount)} (${cart.discountPercentEquivalent.toStringAsFixed(1)}%)'
            '${cart.discountApprovedBy != null ? ' · tasdiqladi: ${cart.discountApprovedBy!.fullName}' : ''}',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
          ),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            'JAMI: ${Fmt.money(cart.total)}',
            style: (compact ? theme.textTheme.headlineSmall : theme.textTheme.headlineMedium)?.copyWith(
              fontWeight: FontWeight.w800,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
      ],
    );

    final discountBtn = OutlinedButton.icon(
      onPressed: cart.isEmpty ? null : () => showDiscountDialog(context, ref),
      icon: const Icon(Icons.percent),
      label: Text(compact ? 'Chegirma' : 'Chegirma (F4)', maxLines: 1, softWrap: false),
    );
    final clearBtn = OutlinedButton.icon(
      onPressed: cart.isEmpty
          ? null
          : () async {
              if (await confirmDialog(context, 'Savatni tozalash', "Savatdagi barcha tovarlar o'chiriladi.")) {
                ref.read(cartProvider.notifier).clear();
              }
            },
      icon: const Icon(Icons.remove_shopping_cart_outlined),
      label: Text(compact ? 'Tozalash' : 'Tozalash (F8)', maxLines: 1, softWrap: false),
    );
    final cashBtn = FilledButton.tonalIcon(
      style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
      onPressed: cart.isEmpty || busy ? null : onQuickCash,
      icon: const Icon(Icons.payments),
      label: Text(compact ? 'Naqd' : 'Naqd (F9)', maxLines: 1, softWrap: false),
    );
    final payBtn = FilledButton.icon(
      style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
      onPressed: cart.isEmpty || busy ? null : onPay,
      icon: busy
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.shopping_cart_checkout),
      label: Text(compact ? "To'lov" : "To'lov (F12)", maxLines: 1, softWrap: false),
    );

    // Tugmalar 2 qatorli to'r: yuqorida yordamchi amallar, pastda to'lov.
    final Widget buttons = compact
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: discountBtn),
                  const SizedBox(width: 8),
                  Expanded(child: clearBtn),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: cashBtn),
                  const SizedBox(width: 8),
                  Expanded(flex: 2, child: payBtn),
                ],
              ),
            ],
          )
        : FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: 460,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: discountBtn),
                      const SizedBox(width: 8),
                      Expanded(child: clearBtn),
                      const SizedBox(width: 8),
                      IconButton.outlined(
                        tooltip: "Oxirgi chekni ko'rish / qayta chop etish",
                        onPressed: onReprint,
                        icon: const Icon(Icons.print_outlined),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(flex: 2, child: cashBtn),
                      const SizedBox(width: 8),
                      Expanded(flex: 3, child: payBtn),
                    ],
                  ),
                ],
              ),
            ),
          );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: compact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [summary, const SizedBox(height: 8), buttons],
              )
            : LayoutBuilder(
                builder: (context, c) => Row(
                  children: [
                    Expanded(child: summary),
                    const SizedBox(width: 12),
                    // Tugmalar ko'pi bilan 460 px, tor oynada esa kenglikning 60% i (FittedBox kichraytiradi).
                    SizedBox(width: c.maxWidth * 0.6 < 460 ? c.maxWidth * 0.6 : 460, child: buttons),
                  ],
                ),
              ),
      ),
    );
  }
}
