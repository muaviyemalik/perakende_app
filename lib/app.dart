import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'features/auth/presentation/providers/auth_provider.dart';

final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

class App extends ConsumerStatefulWidget {
  const App({super.key});

  @override
  ConsumerState<App> createState() => _AppState();
}

class _AppState extends ConsumerState<App> {
  bool _kullaniciHatasiIsleniyor = false;

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);

    ref.listen(kullaniciProvider, (previous, next) {
      next.whenData((result) async {
        final hata = result.hataMesaji;
        if (hata == null) {
          _kullaniciHatasiIsleniyor = false;
          return;
        }

        if (_kullaniciHatasiIsleniyor) {
          return;
        }
        _kullaniciHatasiIsleniyor = true;

        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text(hata),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );

        final isLoggedIn = ref.read(isUserLoggedInProvider);
        if (isLoggedIn && shouldCleanupSessionOnKullaniciError(result.hataTipi)) {
          await cleanupFailedAuthSession(ref);
        }

        _kullaniciHatasiIsleniyor = false;
      });
    });

    return MaterialApp.router(
      scaffoldMessengerKey: scaffoldMessengerKey,
      title: 'Retail Price Lookup',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      routerConfig: router,
    );
  }
}
