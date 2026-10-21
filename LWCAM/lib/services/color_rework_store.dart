import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../db/upload_stats_db.dart';
import 'color_capture_session.dart';
import 'safe_copy.dart';

/// Durable recapture intent. A pointer is published only after the image and
/// its binding have both been written. Readers verify the image before use.
class ColorReworkStore {
  static Future<Directory> _directory(String deviceId, String target) async {
    final key = sha256
        .convert(utf8.encode('$deviceId|${p.normalize(target).toLowerCase()}'))
        .toString();
    final root = await UploadStatsDB().getBaseFolder();
    final dir = Directory(p.join(root, 'color_rework', key));
    await dir.create(recursive: true);
    return dir;
  }

  static Future<File> stage(
    String deviceId,
    String target,
    File source,
    ColorBinding binding,
  ) async {
    final dir = await _directory(deviceId, target);
    final file = File(
      p.join(
        dir.path,
        '${DateTime.now().microsecondsSinceEpoch}${p.extension(source.path)}',
      ),
    );
    await safeCopy(source, file.path);
    final hash = (await sha256.bind(file.openRead()).first).toString();
    final bindingJson = jsonEncode(binding.toJson());
    await writeStringAtomic('${file.path}.color.json', bindingJson);
    await writeStringAtomic(
      p.join(dir.path, 'intent.json'),
      jsonEncode({
        'file': p.basename(file.path),
        'sha256': hash,
        'target': target,
        'binding_sha256': sha256.convert(utf8.encode(bindingJson)).toString(),
      }),
    );
    return file;
  }

  static Future<File?> pending(String deviceId, String target) async {
    final dir = await _directory(deviceId, target);
    final intent = File(p.join(dir.path, 'intent.json'));
    if (!await intent.exists()) return null;
    final data = jsonDecode(await intent.readAsString()) as Map;
    final name = data['file'] as String;
    if (!AdmissibleName.check(name)) {
      throw StateError('Invalid recapture intent filename');
    }
    final file = File(p.join(dir.path, name));
    if (!await file.exists() ||
        (await sha256.bind(file.openRead()).first).toString() !=
            data['sha256']) {
      throw StateError('Recapture staging is damaged; retake this page');
    }
    final sidecar = File('${file.path}.color.json');
    if (!await sidecar.exists() ||
        (await sha256.bind(sidecar.openRead()).first).toString() !=
            data['binding_sha256']) {
      throw StateError('Recapture binding is damaged; retake this page');
    }
    return file;
  }

  static Future<void> complete(String deviceId, String target) async {
    final dir = await _directory(deviceId, target);
    final intent = File(p.join(dir.path, 'intent.json'));
    if (await intent.exists()) await intent.delete();
    // Keep captured generations for recovery; never delete an operator's photo
    // as a side effect of clearing the published intent.
  }
}

class AdmissibleName {
  static bool check(String name) =>
      name.isNotEmpty &&
      name == p.basename(name) &&
      !name.contains(RegExp(r'[\\/:\x00-\x1f]')) &&
      name != '.' &&
      name != '..';
}
