import 'package:path/path.dart' as p;

import '../db/upload_stats_db.dart';

/// Where LWIP's generated files live, for the code in this app that reads them.
///
/// This class used to SUPERVISE LWIP — resolve the bundled python, generate its
/// config, spawn it, bind it to a kill-on-close job, restart it with backoff. All
/// of that is gone, in two steps:
///
///  * Config generation moved to LWCam Admin, which owns every path in it
///    (`lwip_config_writer.dart`).
///  * The process itself moved to a logon entry LWCam Admin registers
///    (`lwip_autostart_service.dart`), so image processing keeps running whether
///    or not an operator has LWCAM open.
///
/// Both had to move together: only one LWIP may run per output root — it takes an
/// orchestrator lock, and a second instance exits — so this app spawning one as
/// well would simply lose a race. LWCAM now only READS what LWIP produced, via
/// ProcessingReportService.
///
/// The old supervisor is in git history if a station ever needs LWIP tied to the
/// app's lifetime again.
class LwipService {
  LwipService._();

  /// LWIP's completion-journal path (fixed under LWCAM_DBs\lwip\runtime) — the
  /// processing report agent polls this. Must stay in agreement with the
  /// `state_file` LWCam Admin writes (lwip_config_writer.dart): disagree and
  /// processing still runs but stops being REPORTED.
  static Future<String> generatedStateFilePath() async {
    final base = await UploadStatsDB().getBaseFolder();
    return p.join(base, 'lwip', 'runtime', 'state.json');
  }

  /// The config LWCam Admin writes and LWIP is started with. Nothing in this app
  /// writes it; the path is here so a diagnostic can point at the right file.
  static Future<String> generatedConfigPath() async {
    final base = await UploadStatsDB().getBaseFolder();
    return p.join(base, 'lwip', 'deskew_crop_config.json');
  }
}
