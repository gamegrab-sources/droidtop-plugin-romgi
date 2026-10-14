import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/prowlarr_service.dart';

final prowlarrServiceProvider = Provider<ProwlarrService>((ref) {
  return ProwlarrService();
});
