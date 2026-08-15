import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../../core/providers/supabase_provider.dart';
import '../../../../providers/cart_provider.dart';
import '../../../../providers/dashboard_stats_provider.dart';
import '../../../../providers/product_provider.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AdminDashboardScreen extends ConsumerStatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  ConsumerState<AdminDashboardScreen> createState() =>
      _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends ConsumerState<AdminDashboardScreen> {
  int _selectedIndex = 0;
  bool _isLoggingOut = false;
  bool _isCompletingSale = false;
  String _scannedBarcode = '';
  RealtimeChannel? _dashboardChannel;
  final MobileScannerController _cameraController = MobileScannerController();

  @override
  void initState() {
    super.initState();
    _setupDashboardRealtime();
  }

  void _setupDashboardRealtime() {
    final supabase = ref.read(supabaseClientProvider);

    _dashboardChannel = supabase
        .channel('admin-dashboard-realtime')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'products',
          callback: (payload) {
            ref.invalidate(dashboardStatsProvider);
            ref.invalidate(productByBarcodeProvider);
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'sales',
          callback: (payload) {
            ref.invalidate(dashboardStatsProvider);
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'sale_items',
          callback: (payload) {
            ref.invalidate(dashboardStatsProvider);
          },
        )
        .subscribe();
  }

  @override
  void dispose() {
    _dashboardChannel?.unsubscribe();
    _cameraController.dispose();
    super.dispose();
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

  Widget _buildScannerTab() {
    final productAsync = _scannedBarcode.isEmpty
        ? null
        : ref.watch(productByBarcodeProvider(_scannedBarcode));

    return Column(
      children: [
        Expanded(
          child: MobileScanner(
            controller: _cameraController,
            errorBuilder: (context, error) {
              final details = error.errorDetails;

              debugPrint('📷 MOBILE SCANNER HATASI');
              debugPrint('Kod: ${error.errorCode}');
              debugPrint('Detay kodu: ${details?.code}');
              debugPrint('Mesaj: ${details?.message}');
              debugPrint('Detay: ${details?.details}');

              return Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        size: 60,
                        color: Colors.red,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Kamera başlatılamadı',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Hata kodu: ${error.errorCode}',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Native kod: ${details?.code ?? "yok"}',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Mesaj: ${details?.message ?? "yok"}',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Detay: ${details?.details ?? "yok"}',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              );
            },
            onDetect: (capture) {
              for (final barcode in capture.barcodes) {
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

  Widget _buildSummaryTab() {
    final statsAsync = ref.watch(dashboardStatsProvider);

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            const SizedBox(height: 16),
            statsAsync.when(
              loading: () => const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(),
                ),
              ),
              error: (error, stackTrace) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('İstatistikler yüklenemedi: $error'),
                ),
              ),
              data: (stats) {
                final totalProducts = stats['totalProducts'] ?? 0;
                final criticalStock = stats['criticalStock'] ?? 0;
                final criticalProductsList =
                    (stats['criticalProductsList'] as List?)
                            ?.cast<Map<String, dynamic>>() ??
                        const [];
                final dailyRevenue =
                    (stats['dailyRevenue'] as num?)?.toDouble() ?? 0.0;
                final employeeSales =
                    (stats['employeeSales'] as List?) ?? const [];

                return SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final isCompact = constraints.maxWidth < 500;

                          return GridView.count(
                            crossAxisCount: isCompact ? 2 : 3,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            childAspectRatio: isCompact ? 1.15 : 1.5,
                            padding: EdgeInsets.zero,
                            children: [
                              _buildStatCard(
                                icon: Icons.inventory,
                                label: 'Toplam Ürün',
                                value: totalProducts.toString(),
                                color: Colors.blueAccent, // Canlı mavi
                                onTap: () =>
                                    _showAllProductsBottomSheet(context),
                              ),
                              _buildStatCard(
                                icon: Icons.warning,
                                label: 'Kritik Stok',
                                value: criticalStock.toString(),
                                color: Colors.redAccent, // Canlı kırmızı
                                onTap: () => _showCriticalProductsBottomSheet(
                                    context, criticalProductsList),
                              ),
                              _buildStatCard(
                                icon: Icons.attach_money,
                                label: 'Bugünkü Ciro',
                                value: '₺$dailyRevenue',
                                color: Colors.green, // Canlı yeşil
                                onTap: () => context.push('/sales-history'),
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Personel Satış Performansı',
                          style:
                              Theme.of(context).textTheme.titleLarge?.copyWith(
                                        fontWeight: FontWeight.bold,
                                      ) ??
                                  const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (employeeSales.isEmpty)
                        const Card(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Text('Henüz satış kaydı yok.'),
                          ),
                        )
                      else
                        ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          padding: EdgeInsets.zero,
                          itemCount: employeeSales.length,
                          itemBuilder: (context, index) {
                            final employee =
                                employeeSales[index] as Map<String, dynamic>;
                            final email =
                                employee['email'] ?? 'Bilinmeyen satıcı';
                            final total =
                                (employee['total'] as num?)?.toDouble() ?? 0.0;

                            return Card(
                              margin: const EdgeInsets.only(bottom: 8),
                              child: ListTile(
                                leading: const Icon(Icons.person_outline),
                                title: Text(email.toString()),
                                trailing: Text(
                                  '${total.toStringAsFixed(2)} ₺',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.green,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      const SizedBox(height: 16),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  context.push('/sales-history');
                },
                icon: const Icon(Icons.history),
                label: const Text(
                  'Satış Geçmişini Gör',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 18,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Card(
        color: color,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 4,
        child: Padding(
          // İç boşluğu 12'den 8'e düşürdük, kart rahatlasın
          padding: const EdgeInsets.all(8.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min, // Sadece gerektiği kadar yer kapla
            children: [
              Icon(icon,
                  size: 28, color: Colors.white), // İkon 32'den 28'e düştü
              const SizedBox(height: 4),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    value,
                    style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white),
                    maxLines: 1,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Flexible(
                child: Text(
                  label,
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Spacer'ı sildik, yerine direk oku koyduk
              const Align(
                alignment: Alignment.bottomRight,
                child:
                    Icon(Icons.chevron_right, color: Colors.white54, size: 18),
              )
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildManagementTab() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton.icon(
              onPressed: () {
                context.push('/add-product');
              },
              icon: const Icon(Icons.add_circle_outline, size: 28),
              label: const Text(
                'Yeni Ürün Ekle',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 20,
                ),
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Stok Güncelle sayfası yakında'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              icon: const Icon(Icons.edit, size: 28),
              label: const Text(
                'Stok Güncelle',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 20,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileTab() {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            const SizedBox(height: 24),
            // Admin Profile Card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.admin_panel_settings,
                      size: 64,
                      color: Colors.purple,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Rolü: Admin',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
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
      _buildSummaryTab(),
      _buildManagementTab(),
      _buildProfileTab(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Dashboard'),
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
        type: BottomNavigationBarType.fixed,
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
            icon: Icon(Icons.dashboard),
            label: 'Özet',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: 'Yönetim',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person),
            label: 'Profil',
          ),
        ],
      ),
    );
  }

  void _showAllProductsBottomSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetCtx) {
        return SizedBox(
          height: MediaQuery.of(sheetCtx).size.height * 0.7,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text('Tüm Ürünler',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              ),
              // GÜVENLİK: allProductsProvider tenant-aware'dir.
              // Supabase RLS + isletme_id filtresi ile yalnızca bu
              // kullanıcının işletmesine ait ürünler listelenir.
              Expanded(
                child: Consumer(
                  builder: (context, ref, _) {
                    final productsAsync = ref.watch(allProductsProvider);
                    return productsAsync.when(
                      loading: () =>
                          const Center(child: CircularProgressIndicator()),
                      error: (e, _) => Center(
                        child: Text('Ürünler yüklenemedi: $e'),
                      ),
                      data: (products) {
                        if (products.isEmpty) {
                          return const Center(
                              child: Text('Sistemde ürün bulunmuyor.'));
                        }
                        return ListView.builder(
                          itemCount: products.length,
                          itemBuilder: (context, index) {
                            final product = products[index];
                            return ListTile(
                              title: Text(product['product_name'] ??
                                  product['name'] ??
                                  'Bilinmeyen Ürün'),
                              trailing: Text('Stok: ${product['stock']}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16)),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showCriticalProductsBottomSheet(
      BuildContext context, List<dynamic> criticalProducts) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) {
        return Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text('Kritik Stoktaki Ürünler',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.redAccent)),
            ),
            Expanded(
              child: criticalProducts.isEmpty
                  ? const Center(
                      child: Text('Kritik seviyede ürün yok, harika!',
                          style: TextStyle(fontSize: 16)))
                  : ListView.builder(
                      itemCount: criticalProducts.length,
                      itemBuilder: (context, index) {
                        final product = criticalProducts[index];
                        return ListTile(
                          leading: const Icon(Icons.warning,
                              color: Colors.redAccent),
                          title: Text(product['product_name'] ??
                              product['name'] ??
                              'Bilinmeyen Ürün'),
                          trailing: Text(
                            'Kalan: ${product['stock']}',
                            style: const TextStyle(
                                color: Colors.redAccent,
                                fontWeight: FontWeight.bold,
                                fontSize: 16),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
