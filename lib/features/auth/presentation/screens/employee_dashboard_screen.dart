import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

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
  final MobileScannerController _cameraController = MobileScannerController();

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
    super.dispose();
  }

  Widget _buildScannerTab() {
    final productAsync = _scannedBarcode.isEmpty
        ? null
        : ref.watch(productByBarcodeProvider(_scannedBarcode));

    return Column(
      children: [
        Expanded(
          child: MobileScanner(
            controller: _cameraController,
            onDetect: (capture) {
              final List<Barcode> barcodes = capture.barcodes;
              for (final barcode in barcodes) {
                if (barcode.rawValue != null && barcode.rawValue!.isNotEmpty) {
                  setState(() {
                    _scannedBarcode = barcode.rawValue!;
                  });
                  break;
                }
              }
            },
          ),
        ),
        Expanded(
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
                      const Text(
                        'Son Okutulan Barkod:',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
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
                        const Center(
                          child: Text(
                            'Barkod bekleniyor...',
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey,
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
    return const Center(
      child: Text(
        'Ürün Listesi',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
      ),
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
