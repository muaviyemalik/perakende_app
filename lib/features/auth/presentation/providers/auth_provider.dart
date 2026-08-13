import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/providers/supabase_provider.dart';

// Provider to track current auth session
final authStateProvider = StreamProvider<Session?>((ref) {
  final supabase = ref.watch(supabaseClientProvider);
  return supabase.auth.onAuthStateChange.map((data) => data.session);
});

// Provider to check if user is logged in
final isUserLoggedInProvider = Provider<bool>((ref) {
  final session = ref.watch(authStateProvider);
  return session.maybeWhen(
    data: (session) => session != null,
    orElse: () => false,
  );
});

// Provider to get current user
final currentUserProvider = Provider<User?>((ref) {
  final session = ref.watch(authStateProvider);
  return session.maybeWhen(
    data: (session) => session?.user,
    orElse: () => null,
  );
});

// Provider to get user role from profiles table
final userRoleProvider = FutureProvider<String?>((ref) async {
  final currentUser = ref.watch(currentUserProvider);

  if (currentUser == null) {
    return null;
  }

  try {
    final supabase = ref.watch(supabaseClientProvider);
    final response = await supabase
        .from('profiles')
        .select('role')
        .eq('id', currentUser.id)
        .single();

    return response['role'] as String?;
  } catch (e) {
    return null;
  }
});
