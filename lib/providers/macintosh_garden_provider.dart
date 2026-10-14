import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/macintosh_garden_service.dart';
import 'internet_archive_auth_provider.dart';

final macintoshGardenServiceProvider = Provider<MacintoshGardenService>((ref) {
  final auth = ref.watch(internetArchiveAuthProvider);
  return MacintoshGardenService(auth: auth);
});
