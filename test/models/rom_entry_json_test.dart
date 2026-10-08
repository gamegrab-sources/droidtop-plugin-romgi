import 'package:flutter_test/flutter_test.dart';
import 'package:romgi/models/rom_entry.dart';

void main() {
  test('RomEntry boxart URL survives the JSON round trip', () {
    const entry = RomEntry(
      slug: 'sample-game',
      title: 'Sample Game',
      platform: 'snes',
      boxartUrl: 'https://example.invalid/boxart.png',
      regions: [],
      links: [],
    );

    final decoded = RomEntry.fromJson(entry.toJson());

    expect(decoded.boxartUrl, entry.boxartUrl);
    expect(entry.toJson(), containsPair('boxart_url', entry.boxartUrl));
  });
}
