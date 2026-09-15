import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/services/lwip_autostart_service.dart';
import 'package:path/path.dart' as p;

/// The generated launcher must carry a __main__ guard, and sys.path must be set
/// OUTSIDE it.
///
/// LWIP's orchestrator runs image work in a ProcessPoolExecutor. On Windows,
/// multiprocessing starts each worker by re-executing the parent's __main__
/// FILE - this launcher - as __mp_main__. Without the guard every worker reaches
/// run_module, sees run_name="__main__", and starts a second orchestrator, which
/// then dies on the orchestrator lock the parent already holds. With the guard,
/// a worker only defines names.
///
/// sys.path.insert has to stay outside the guard for the opposite reason: the
/// worker never enters the guarded block, but it still has to import
/// deskew_crop_tool to unpickle the function it was handed.
///
/// Asserting on generated source is blunt, but this is a property whose absence
/// is invisible until a real pool spawns on a real station.
void main() {
  test('the launcher guards __main__ and sets sys.path outside it', () async {
    final temp = await Directory.systemTemp.createTemp('lwip_launcher_');
    try {
      final root = p.join(temp.path, 'LWCAM', 'LWIP');
      await Directory(p.join(root, 'backend')).create(recursive: true);
      // Into the temp dir, NOT the station's real launcher path: without a
      // destination this test rewrites the autostart launcher of whatever
      // machine runs the suite, pointing it at this temp tree - which is
      // deleted below, leaving LWIP unable to start at the next logon.
      final file = await writeLwipLauncher(
        root,
        destination: p.join(temp.path, 'lwip_autostart.py'),
      );
      final text = await file.readAsString();

      expect(text, contains('if __name__ == "__main__":'));
      expect(text, contains('runpy.run_module'));
      expect(
        text.indexOf('sys.path.insert'),
        lessThan(text.indexOf('if __name__')),
        reason: 'workers need backend importable but never reach the guard',
      );
      // The orchestrator must only ever be started from the guarded block.
      expect(
        text.indexOf('runpy.run_module'),
        greaterThan(text.indexOf('if __name__')),
      );
      expect(text, contains(p.join(root, 'backend')));
    } finally {
      await temp.delete(recursive: true);
    }
  });
}
