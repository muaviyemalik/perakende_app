import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:perakende_app/providers/cart_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  
  group('CartNotifier Stock Tests', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
    });

    tearDown(() {
      container.dispose();
    });

    testWidgets('addToCart with stock validation', (WidgetTester tester) async {
      final cartNotifier = container.read(cartProvider.notifier);

      // 1. Başlangıçta 5 stok olan üründen sepete 4 adet ekle
      var error = cartNotifier.addToCart(
        productId: 'p1',
        name: 'Test Ürün',
        price: 10.0,
        stock: 5,
        quantity: 4,
      );
      
      expect(error, isNull); // Başarılı olmalı
      
      var cart = container.read(cartProvider);
      expect(cart.length, 1);
      expect(cart.first.quantity, 4);

      // 2. Sepete 2 adet daha eklemeye çalış (4 + 2 = 6 > 5)
      error = cartNotifier.addToCart(
        productId: 'p1',
        name: 'Test Ürün',
        price: 10.0,
        stock: 5,
        quantity: 2,
      );

      // İşlem reddedilmeli ve hata mesajı dönmeli
      expect(error, 'Stokta yalnızca 5 adet bulunuyor.');

      // Sepet miktarı hala 4 olmalı
      cart = container.read(cartProvider);
      expect(cart.first.quantity, 4);

      // 3. Sepete 1 adet daha ekle (4 + 1 = 5 <= 5)
      error = cartNotifier.addToCart(
        productId: 'p1',
        name: 'Test Ürün',
        price: 10.0,
        stock: 5,
        quantity: 1,
      );

      expect(error, isNull);
      
      cart = container.read(cartProvider);
      expect(cart.first.quantity, 5);
      
      // 4. Sonraki ekleme başarısız olmalı
      error = cartNotifier.addToCart(
        productId: 'p1',
        name: 'Test Ürün',
        price: 10.0,
        stock: 5,
        quantity: 1,
      );

      expect(error, 'Stokta yalnızca 5 adet bulunuyor.');
    });
    
    testWidgets('updateQuantity with stock validation', (WidgetTester tester) async {
      final cartNotifier = container.read(cartProvider.notifier);

      // Başlangıçta 3 stoklu 1 adet ekle
      cartNotifier.addToCart(
        productId: 'p2',
        name: 'Test Ürün 2',
        price: 15.0,
        stock: 3,
        quantity: 1,
      );

      // delta: 2 -> miktar 3 olur
      var error = cartNotifier.updateQuantity('p2', delta: 2);
      expect(error, isNull);
      
      var cart = container.read(cartProvider);
      expect(cart.first.quantity, 3);
      
      // delta: 1 -> miktar 4 olur, reddedilmeli
      error = cartNotifier.updateQuantity('p2', delta: 1);
      expect(error, 'Stokta yalnızca 3 adet bulunuyor.');
      
      cart = container.read(cartProvider);
      expect(cart.first.quantity, 3); // Değişmemeli
      
      // delta: -1 -> miktar 2 olur
      error = cartNotifier.updateQuantity('p2', delta: -1);
      expect(error, isNull);
      
      cart = container.read(cartProvider);
      expect(cart.first.quantity, 2);
    });
  });
}
