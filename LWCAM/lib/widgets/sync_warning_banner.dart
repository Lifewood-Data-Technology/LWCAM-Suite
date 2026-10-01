import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../services/sync_service.dart';

/// Warns about database-sync trouble that needs a person: an old database
/// schema, or records held after too many failed sends. Nothing is shown when
/// sync is off or healthy.
class SyncWarningBanner extends StatelessWidget {
  const SyncWarningBanner({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Get.isRegistered<SyncService>()) return const SizedBox.shrink();
    final sync = Get.find<SyncService>();
    return Obx(() {
      final schema = sync.schemaWarning.value;
      final held = sync.heldCount.value;
      if (schema == null && held == 0) return const SizedBox.shrink();
      return Material(
        color: Colors.orange.shade100,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.deepOrange),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  schema ??
                      '$held record${held == 1 ? '' : 's'} could not be sent '
                          'to the database and ${held == 1 ? 'is' : 'are'} '
                          'waiting.',
                  style: const TextStyle(color: Colors.black87),
                ),
              ),
              if (schema == null)
                TextButton(
                  onPressed: sync.retryHeld,
                  child: const Text('Try again'),
                ),
            ],
          ),
        ),
      );
    });
  }
}
