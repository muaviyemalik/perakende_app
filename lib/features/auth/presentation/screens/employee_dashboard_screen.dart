import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../../core/utils/barcode_utils.dart';
import '../../../../providers/cart_provider.dart';
import '../../../../providers/product_provider.dart';
import '../providers/auth_provider.dart';

class EmployeeDashboardScreen extends ConsumerStatefulWidget {
  const EmployeeDashboardScreen({super.key});

  @override
  ConsumerState<EmployeeDashboardScreen> createState() =>
      _EmployeeDashboardScreenState();
}

class _EmployeeDashboardScreenState
    extends ConsumerState<EmployeeDashboardScreen> {
  int _selectedIndex = 0;
  bool _isLoggingOut = false;
  bool _isCompletingSale = false;
  String _scannedBarcode = '';
  String _lastInvalidBarcode = '';
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _manualBarcodeController = TextEditingController();
  final MobileScannerController _cameraController = MobileScannerController();
  final FocusNode _manualBarcodeFocus = FocusNode();
  bool _isSearchingManualBarcode = false;
  bool _showManualBarcodeField = false;

  Future<void> _handleManualBarcodeSubmit(String value) async {
    final barcode = value.trim();
    if (barcode.isEmpty) return;

    if (!BarcodeUtils.isValidBarcode(barcode)) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Geçersiz barkod: Sadece rakam içermelidir.'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    setState(() {
      _isSearchingManualBarcode = true;
    });

    try {
      final product = await ref.read(productByBarcodeProvider(barcode).future);
      if (!mounted) return;

      if (product != null) {
        final name = product['name'] ?? 'Bilinmeyen ürün';
        final rawPrice = product['price'];
        final price = rawPrice is num ? rawPrice.toDouble() : 0.0;
        final productId = (product['id'] ?? barcode).toString();

        ref.read(cartProvider.notifier).addToCart(
              productId: productId,
              name: name,
              price: price,
            );

        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$name sepete eklendi!'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
        _manualBarcodeController.clear();
        setState(() {
          _showManualBarcodeField = false;
        });
      } else {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Bu barkoda ait ürün bulunamadı!'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Hata oluştu: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 2),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSearchingManualBarcode = false;
        });
      }
    }
  }

  Future<void> _handleLogout() async {
    setState(() => _isLoggingOut = true);

    try {
      await performLogout(ref);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Çıkış hatası: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoggingOut = false);
      }
    }
  }

  void _showCartBottomSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return Consumer(
          builder: (context, ref, child) {
            final items = ref.watch(cartProvider);
            final cartNotifier = ref.read(cartProvider.notifier);
            final totalAmount = cartNotifier.totalAmount;

            return Container(
              height: MediaQuery.of(context).size.height * 0.85,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Satış Sepeti',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ) ??
                            const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                    ),
                    Expanded(
                      child: items.isEmpty
                          ? const Center(
                              child: Text('Sepet boş'),
                            )
                          : ListView.builder(
                              itemCount: items.length,
                              itemBuilder: (context, index) {
                                final item = items[index];
                                return ListTile(
                                  title: Text(item.name),
                                  subtitle: Text(
                                    'Birim fiyat: ₺${item.price.toStringAsFixed(2)}',
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        onPressed: () {
                                          cartNotifier.updateQuantity(
                                            item.product_id,
                                            delta: -1,
                                          );
                                        },
                                        icon: const Icon(
                                            Icons.remove_circle_outline),
                                      ),
                                      Text(
                                        '${item.quantity}',
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      IconButton(
                                        onPressed: () {
                                          cartNotifier.updateQuantity(
                                            item.product_id,
                                            delta: 1,
                                          );
                                        },
                                        icon: const Icon(
                                            Icons.add_circle_outline),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border(
                          top: BorderSide(color: Colors.grey.shade200),
                        ),
                      ),
                      child: Column(
                        children: [
                          Text(
                            'Genel Toplam: ${totalAmount.toStringAsFixed(2)} ₺',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Colors.green.shade700,
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: _isCompletingSale
                                  ? null
                                  : () async {
                                      final messenger =
                                          ScaffoldMessenger.maybeOf(context);
                                      final navigator =
                                          Navigator.of(sheetContext);

                                      setState(() => _isCompletingSale = true);

                                      try {
                                        final result = await ref
                                            .read(cartProvider.notifier)
                                            .completeSale();

                                        if (!mounted) return;

                                        if (result == null) {
                                          // Başarılı
                                          if (navigator.canPop()) {
                                            navigator.pop();
                                          }
                                          messenger?.showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                'Satış başarıyla tamamlandı ve stok güncellendi!',
                                              ),
                                              backgroundColor: Colors.green,
                                            ),
                                          );
                                        } else {
                                          // Başarısız - hata mesajını göster
                                          messenger?.showSnackBar(
                                            SnackBar(
                                              content: Text(result),
                                              backgroundColor: Colors.red,
                                            ),
                                          );
                                        }
                                      } catch (_) {
                                        if (!mounted) return;
                                        messenger?.showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                                'Satış işlemi başarısız oldu'),
                                            backgroundColor: Colors.red,
                                          ),
                                        );
                                      } finally {
                                        if (mounted) {
                                          setState(
                                              () => _isCompletingSale = false);
                                        }
                                      }
                                    },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                foregroundColor: Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 18),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: _isCompletingSale
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text(
                                      'Satışı Tamamla',
                                      style: TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
    _cameraController.dispose();
    _searchController.dispose();
    _manualBarcodeController.dispose();
    _manualBarcodeFocus.dispose();
    super.dispose();
  }

  Widget _buildScannerTab() {
    final productAsync = _scannedBarcode.isEmpty
        ? null
        : ref.watch(productByBarcodeProvider(_scannedBarcode));

    return Column(
      children: [
        Expanded(
          flex: 2,
          child: MobileScanner(
            controller: _cameraController,
            onDetect: (capture) {
              final List<Barcode> barcodes = capture.barcodes;
              for (final barcode in barcodes) {
                final rawValue = barcode.rawValue;
                if (rawValue != null && rawValue.isNotEmpty) {
                  if (rawValue != _scannedBarcode) {
                    if (BarcodeUtils.isValidBarcode(rawValue)) {
                      setState(() {
                        _scannedBarcode = rawValue;
                      });
                    } else if (rawValue != _lastInvalidBarcode) {
                      setState(() {
                        _lastInvalidBarcode = rawValue;
                      });
                      ScaffoldMessenger.of(context).clearSnackBars();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Geçersiz barkod: Sadece rakam içermelidir.'),
                          backgroundColor: Colors.red,
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                  }
                  break;
                }
              }
            },
          ),
        ),
        Expanded(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (_showManualBarcodeField) ...[
                        TextField(
                          controller: _manualBarcodeController,
                          focusNode: _manualBarcodeFocus,
                          keyboardType: TextInputType.number,
                          inputFormatters: BarcodeUtils.barcodeInputFormatters,
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                            hintText: 'Barkodu manuel girin...',
                            prefixIcon: const Icon(Icons.barcode_reader),
                            suffixIcon: IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                setState(() {
                                  _showManualBarcodeField = false;
                                  _manualBarcodeController.clear();
                                });
                              },
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            filled: true,
                            fillColor: Colors.grey.shade50,
                          ),
                          onSubmitted: _handleManualBarcodeSubmit,
                        ),
                        const SizedBox(height: 16),
                        if (_isSearchingManualBarcode)
                          const CircularProgressIndicator(),
                      ] else ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text(
                              'Son Okutulan Barkod:',
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit, size: 20, color: Colors.blue),
                              onPressed: () {
                                setState(() {
                                  _showManualBarcodeField = true;
                                });
                                _manualBarcodeFocus.requestFocus();
                              },
                              tooltip: 'Manuel barkod gir',
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.blue.shade200),
                          ),
                          child: Text(
                            _scannedBarcode.isEmpty
                                ? 'Bekleniyor...'
                                : _scannedBarcode,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.blue.shade700,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Divider(),
                        const SizedBox(height: 16),
                        if (_scannedBarcode.isEmpty)
                          GestureDetector(
                            onTap: () {
                              setState(() {
                                _showManualBarcodeField = true;
                              });
                              _manualBarcodeFocus.requestFocus();
                            },
                            behavior: HitTestBehavior.opaque,
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(32.0),
                              child: const Column(
                                children: [
                                  Icon(Icons.qr_code_scanner, size: 48, color: Colors.grey),
                                  SizedBox(height: 16),
                                  Text(
                                    'Barkod bekleniyor...\n(Manuel giriş için tıklayın)',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else
                          productAsync!.when(
                          loading: () => const Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator(),
                                SizedBox(height: 12),
                                Text(
                                  'Ürün aranıyor...',
                                  style: TextStyle(fontSize: 16),
                                ),
                              ],
                            ),
                          ),
                          error: (error, stackTrace) => Center(
                            child: Text(
                              'Hata: $error',
                              style: const TextStyle(
                                color: Colors.red,
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          data: (product) {
                            if (product == null) {
                              return const Center(
                                child: Text(
                                  'Bu barkoda ait kayıtlı ürün bulunamadı!',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.red,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              );
                            }

                            final name = product['name'] ?? 'Bilinmeyen ürün';
                            final rawPrice = product['price'];
                            final price = rawPrice is num ? rawPrice : 0;
                            final stock = product['stock'] ?? 0;

                            final productId =
                                (product['id'] ?? _scannedBarcode).toString();
                            final unitPrice = price.toDouble();

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                const Text(
                                  'Ürün Bilgileri:',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.grey,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.black87,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'Fiyat: ₺${unitPrice.toStringAsFixed(2)}',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 26,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.green,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'Stok: $stock adet',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.grey.shade700,
                                  ),
                                ),
                                const SizedBox(height: 20),
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton.icon(
                                    onPressed: () {
                                      ref.read(cartProvider.notifier).addToCart(
                                            productId: productId,
                                            name: name,
                                            price: unitPrice,
                                          );
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                          content: Text('Ürün sepete eklendi'),
                                          duration: Duration(seconds: 2),
                                        ),
                                      );
                                    },
                                    icon: const Icon(Icons.add_shopping_cart),
                                    label: const Text(
                                      'Sepete Ekle',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.green,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 16,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildProductsTab() {
    final productsAsync = ref.watch(allProductsProvider);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Ürün adı veya barkod ile ara...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        setState(() {
                          _searchQuery = '';
                        });
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              filled: true,
              fillColor: Colors.grey.shade50,
            ),
            onChanged: (value) {
              setState(() {
                _searchQuery = value.toLowerCase();
              });
            },
          ),
        ),
        Expanded(
          child: productsAsync.when(
            loading: () => const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Ürünler yükleniyor...'),
                ],
              ),
            ),
            error: (error, stack) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off, size: 64, color: Colors.grey),
                    const SizedBox(height: 16),
                    const Text(
                      'Ürünler alınamadı',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'İnternet bağlantınızı kontrol edin. (Hata: $error)',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: () => ref.refresh(allProductsProvider),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Tekrar Dene'),
                    ),
                  ],
                ),
              ),
            ),
            data: (products) {
              if (products.isEmpty) {
                return const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.inventory_2_outlined,
                          size: 64, color: Colors.grey),
                      SizedBox(height: 16),
                      Text(
                        'İşletmenize ait ürün bulunamadı.',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                );
              }

              final filteredProducts = products.where((p) {
                final name = (p['name'] ?? '').toString().toLowerCase();
                final barcode = (p['barcode'] ?? '').toString().toLowerCase();
                return name.contains(_searchQuery) ||
                    barcode.contains(_searchQuery);
              }).toList();

              if (filteredProducts.isEmpty) {
                return Center(
                  child: Text(
                    'Aramanızla eşleşen ürün bulunamadı: "$_searchQuery"',
                    style: const TextStyle(color: Colors.grey, fontSize: 16),
                  ),
                );
              }

              return RefreshIndicator(
                onRefresh: () async {
                  return ref.refresh(allProductsProvider);
                },
                child: ListView.separated(
                  padding: const EdgeInsets.only(bottom: 80), // Fab icin bosluk
                  itemCount: filteredProducts.length,
                  separatorBuilder: (context, index) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final product = filteredProducts[index];
                    final name = product['name'] ?? 'Bilinmeyen Ürün';
                    final barcode = product['barcode'] ?? '-';
                    final rawPrice = product['price'];
                    final price = rawPrice is num ? rawPrice.toDouble() : 0.0;
                    final stock = product['stock'] ?? 0;
                    final productId = (product['id'] ?? '').toString();

                    final isCriticalStock = stock <= 5;

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      leading: CircleAvatar(
                        backgroundColor: Colors.blue.shade100,
                        child: const Icon(Icons.inventory_2, color: Colors.blue),
                      ),
                      title: Text(
                        name,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 4),
                          Text('Barkod: $barcode'),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Text(
                                'Stok: $stock',
                                style: TextStyle(
                                  color: isCriticalStock
                                      ? Colors.red.shade700
                                      : Colors.green.shade700,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (isCriticalStock) ...[
                                const SizedBox(width: 4),
                                Icon(Icons.warning,
                                    size: 16, color: Colors.red.shade700),
                              ],
                            ],
                          ),
                        ],
                      ),
                      trailing: Text(
                        '₺${price.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.blue,
                        ),
                      ),
                      onTap: () {
                        ref.read(cartProvider.notifier).addToCart(
                              productId: productId,
                              name: name,
                              price: price,
                            );
                        ScaffoldMessenger.of(context).clearSnackBars();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('$name sepete eklendi!'),
                            backgroundColor: Colors.green,
                            duration: const Duration(seconds: 1),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildProfileTab() {
    final userRole = ref.watch(userRoleProvider);

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            const SizedBox(height: 24),
            // Profile Card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.account_circle,
                      size: 64,
                      color: Colors.blue,
                    ),
                    const SizedBox(height: 16),
                    userRole.when(
                      data: (rol) {
                        return Text(
                          'Rolü: ${rol != null ? rolGoruntule(rol) : 'Bilinmiyor'}',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        );
                      },
                      loading: () => const Text('Rol yükleniyor...'),
                      error: (error, stack) => const Text('Rol alınamadı'),
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _isLoggingOut ? null : _handleLogout,
                        icon: const Icon(Icons.logout),
                        label: const Text('Çıkış Yap'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cartItems = ref.watch(cartProvider);
    final cartItemCount = cartItems.fold<int>(
      0,
      (previousValue, item) => previousValue + item.quantity,
    );
    final List<Widget> pages = [
      _buildScannerTab(),
      _buildProductsTab(),
      _buildProfileTab(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Employee Dashboard'),
        elevation: 0,
      ),
      body: pages[_selectedIndex],
      floatingActionButton: _selectedIndex == 0 && cartItems.isNotEmpty
          ? Badge(
              label: Text(
                '$cartItemCount',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
              backgroundColor: Colors.red,
              alignment: Alignment.topRight,
              child: FloatingActionButton(
                onPressed: _showCartBottomSheet,
                backgroundColor: Colors.green,
                child: const Icon(Icons.shopping_cart, size: 28),
              ),
            )
          : null,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) {
          setState(() => _selectedIndex = index);
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.qr_code_scanner),
            label: 'Okuyucu',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.shopping_bag),
            label: 'Ürünler',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person),
            label: 'Profil',
          ),
        ],
      ),
    );
  }
}
