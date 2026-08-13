import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../providers/sales_provider.dart';

class SalesHistoryScreen extends ConsumerWidget {
  const SalesHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final salesAsync = ref.watch(salesHistoryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Satış Geçmişi'),
      ),
      body: salesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Satış geçmişi yüklenemedi: $error'),
          ),
        ),
        data: (sales) {
          if (sales.isEmpty) {
            return const Center(
              child: Text('Henüz satış kaydı yok.'),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: sales.length,
            itemBuilder: (context, index) {
              final sale = sales[index];
              final saleItems = (sale['sale_items'] as List?) ?? const [];
              final totalAmount = (sale['total_amount'] is num)
                  ? (sale['total_amount'] as num).toDouble()
                  : 0.0;
              final profile = sale['profiles'];
              final sellerEmail = profile is Map
                  ? (profile['email'] ?? 'Bilinmeyen satıcı')
                  : 'Bilinmeyen satıcı';

              DateTime saleDate;
              try {
                saleDate = DateTime.parse(
                  sale['created_at'] ?? DateTime.now().toIso8601String(),
                );
              } catch (_) {
                saleDate = DateTime.now();
              }

              final formattedDate =
                  DateFormat('dd.MM.yyyy - HH:mm').format(saleDate);

              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ExpansionTile(
                  title: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              formattedDate,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Satıcı: $sellerEmail',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: Colors.grey.shade700),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${totalAmount.toStringAsFixed(2)} ₺',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.green.shade700,
                        ),
                      ),
                    ],
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    if (saleItems.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text('Satış detay bulunmuyor.'),
                      )
                    else
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: saleItems.map<Widget>((saleItem) {
                          final product = saleItem['products'];
                          final productName = product is Map
                              ? (product['name'] ?? 'Ürün')
                              : 'Ürün';
                          final quantity = saleItem['quantity'] ?? 0;
                          final unitPrice = (saleItem['unit_price'] is num)
                              ? (saleItem['unit_price'] as num).toDouble()
                              : 0.0;

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              '$productName x $quantity - ${unitPrice.toStringAsFixed(2)} ₺',
                              style: const TextStyle(fontSize: 14),
                            ),
                          );
                        }).toList(),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
