// ignore_for_file: avoid_print

// Holds station-level settings for the LWCAM capture app. There is no page
// here despite the name; only SettingsController lives in this file.
// Values come from the node config written by LWCam Admin.
import 'package:get/get.dart';
import 'package:lwcam/services/node_config_service.dart';

/// The per-station state LWCAM's capture/transfer flows read. There is NO
/// Settings PAGE in LWCAM anymore (removed 2026-07-21, same day as the
/// SuperAdmin split): every station-level setting — the image destination
/// root, the sync connection, the capture-outbox toggle — is configured
/// exclusively from LWCam Admin's Station Setup, which writes the shared
/// `lwcam_node_config.json` this controller reads. Only SuperAdmin
/// configures a station; LWCAM users (Admin included) can't change any of
/// it.
///
/// The file keeps its historical name (`settings_page.dart`) because half
/// a dozen imports across gallery/upload/box flows depend on it — same
/// convention as the `upload_controller.dart` typo.
class SettingsController extends GetxController {
  /// The image destination root transfers land in — read from
  /// `NodeConfig.destinationPath`, set only by LWCam Admin's Station Setup.
  /// Empty means the station isn't configured yet; uploads refuse to start.
  final destinationPath = ''.obs;

  /// Gallery filter: whether already-transferred images stay visible (and
  /// get re-sent as overwrites). Session-only, deliberately not persisted.
  final includeUploaded = false.obs;

  @override
  void onInit() {
    super.onInit();
    reloadDestination();
  }

  /// Re-reads the destination from `lwcam_node_config.json` (from DISK —
  /// LWCam Admin may have rewritten it since this process loaded it).
  /// Called at controller creation and on every login, so a Station Setup
  /// change lands without restarting LWCAM.
  Future<void> reloadDestination() async {
    if (!Get.isRegistered<NodeConfigService>()) return;
    try {
      final config = await Get.find<NodeConfigService>().reload();
      destinationPath.value = config.destinationPath?.trim() ?? '';
    } catch (e) {
      print('⚠️ Destination reload failed: $e');
    }
  }
}
