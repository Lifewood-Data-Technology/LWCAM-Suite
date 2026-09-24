import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/pages/gallery_page.dart';

/// The live-sync baseline guard.
///
/// An unreachable phone and an empty DCIM both list nothing, and the scan used
/// to read only stdout — so it could not tell them apart. Both readings are
/// damaging, in opposite directions:
///
///  * unreachable mistaken for empty → the baseline is left empty but treated
///    as seeded, so the first successful listing after the phone reconnects
///    looks like a burst of new captures and the WHOLE camera roll is claimed
///    into the folder being captured (what happened on SAX01 box 1: folder
///    created 16:06:09, 49 pre-existing photos assigned 16:09:11-16:09:56);
///  * empty mistaken for unreachable → the baseline is left unseeded, so the
///    operator's first real capture is adopted as the baseline instead of
///    being ingested, and the page silently loses it.
///
/// adb forwards the remote exit status, so exit 0 is the discriminator.
void main() {
  group('deviceAnsweredListing', () {
    test('a populated camera folder answers', () {
      expect(
        deviceAnsweredListing(
          exitCode: 0,
          stdout: 'IMG_20260909_160701.jpg\nIMG_20260909_160712.jpg',
        ),
        isTrue,
      );
    });

    test('a reachable phone with an EMPTY camera folder still answers', () {
      // The regression this guards: exit 0 with no output is a real, seeded
      // baseline of zero files, so the next capture is ingested as a capture.
      expect(deviceAnsweredListing(exitCode: 0, stdout: ''), isTrue);
    });

    test('an unreachable device does not answer', () {
      // `adb shell` with no device: non-zero exit, nothing on stdout — byte
      // for byte the same stdout as the empty folder above.
      expect(deviceAnsweredListing(exitCode: 1, stdout: ''), isFalse);
    });

    test('a wrong candidate path does not answer', () {
      expect(
        deviceAnsweredListing(
          exitCode: 1,
          stdout: 'ls: /sdcard/DCIM/Camera: No such file or directory',
        ),
        isFalse,
      );
    });

    test('"No such file" never answers, even on a zero exit', () {
      // Some adb/shell combinations return the shell's own status rather than
      // ls's. The message is then the only signal left.
      expect(
        deviceAnsweredListing(
          exitCode: 0,
          stdout: 'ls: /sdcard/DCIM/Camera: No such file or directory',
        ),
        isFalse,
      );
    });
  });
}
