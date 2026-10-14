import 'package:flutter/material.dart';

import '../services/live_search_source.dart';

/// Marks a live search result (`RomEntry.isLive`), naming its source in the
/// tooltip. [compact] is the round icon the grid card overlays on the cover;
/// otherwise it is the "Live" chip of a list row.
class LiveSourceBadge extends StatelessWidget {
  final String sourceId;
  final bool compact;

  const LiveSourceBadge({
    super.key,
    required this.sourceId,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final message =
        'Live result from ${liveSourceName(sourceId)}, not the offline catalog';
    if (compact) {
      return Tooltip(
        message: message,
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Colors.blue,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.podcasts, size: 14, color: Colors.white),
        ),
      );
    }
    return Tooltip(
      message: message,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.blue.shade100,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.podcasts, size: 10, color: Colors.blue.shade700),
            const SizedBox(width: 2),
            Text(
              'Live',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.blue.shade700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
