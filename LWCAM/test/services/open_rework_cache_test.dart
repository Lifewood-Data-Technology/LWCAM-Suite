import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/services/open_rework_cache.dart';
import 'package:lwcam/services/rework_service.dart';

ReworkItem _item({
  required String projectKey,
  required String boxName,
  int folderSeq = 1,
  String imageName = 'a.jpg',
}) =>
    ReworkItem(
      reworkId: folderSeq * 100 + imageName.hashCode % 100,
      projectKey: projectKey,
      projectId: 'PRJ-1',
      boxName: boxName,
      folderSeq: folderSeq,
      folderName: 'F$folderSeq',
      folderPath: r'D:\out\20260730\F1',
      qcStatus: 'REWORK',
      imageName: imageName,
      reason: 'blurry',
      reworkType: 'Recapture',
    );

/// Returns a canned list, or throws like the real service does when PG is down.
class _FakeReworkService extends ReworkService {
  _FakeReworkService(this._items, {this.error});
  final List<ReworkItem> _items;
  final Object? error;
  int calls = 0;

  @override
  Future<List<ReworkItem>> fetchOpenRework(String username) async {
    calls++;
    if (error != null) throw error!;
    return _items;
  }
}

void main() {
  setUp(OpenReworkCache.instance.clear);
  tearDown(OpenReworkCache.instance.clear);

  final cache = OpenReworkCache.instance;

  test('groups items by box and counts them', () async {
    await cache.refresh('Jamie',
        service: _FakeReworkService([
          _item(projectKey: 'pk1', boxName: 'BOX-9', imageName: 'a.jpg'),
          _item(projectKey: 'pk1', boxName: 'BOX-9', imageName: 'b.jpg'),
          _item(projectKey: 'pk1', boxName: 'BOX-10', imageName: 'c.jpg'),
        ]));
    expect(cache.itemsForBox('pk1', 'BOX-9'), hasLength(2));
    expect(cache.itemsForBox('pk1', 'BOX-10'), hasLength(1));
    expect(cache.hasRework('pk1', 'BOX-9'), isTrue);
    expect(cache.hasRework('pk1', 'BOX-404'), isFalse);
    expect(cache.lastError, isNull);
    expect(cache.lastRefreshed, isNotNull);
  });

  // The local box name (capture_boxes.box_details) and the cloud's box_name can
  // differ in case; boxNameExists is case-insensitive for the same reason.
  test('matches box names case-insensitively and ignores surrounding space',
      () async {
    await cache.refresh('Jamie',
        service: _FakeReworkService([
          _item(projectKey: 'PK1', boxName: 'Box-9'),
        ]));
    expect(cache.hasRework('pk1', 'BOX-9'), isTrue);
    expect(cache.hasRework('pk1', '  box-9 '), isTrue);
  });

  // The box list has to survive an unreachable PG. ReworkService throws on
  // purpose (an empty worklist screen would read as "nothing to do"), so the
  // cache is where that gets absorbed.
  test('a failed read yields an empty cache instead of throwing', () async {
    await cache.refresh('Jamie',
        service: _FakeReworkService(const [],
            error: StateError('Cannot reach the database.')));
    expect(cache.hasRework('pk1', 'BOX-9'), isFalse);
    expect(cache.lastError, contains('Cannot reach the database'));
    expect(cache.lastRefreshed, isNull);
  });

  // Stale badges are worse than no badges: a closed request that keeps showing
  // sends the operator to re-photograph an image that is already fixed.
  test('a failed read clears previously cached items', () async {
    await cache.refresh('Jamie',
        service: _FakeReworkService([_item(projectKey: 'pk1', boxName: 'BOX-9')]));
    expect(cache.hasRework('pk1', 'BOX-9'), isTrue);

    await cache.refresh('Jamie',
        service: _FakeReworkService(const [], error: StateError('offline')));
    expect(cache.hasRework('pk1', 'BOX-9'), isFalse);
  });

  test('a successful empty read clears items and reports no error', () async {
    await cache.refresh('Jamie',
        service: _FakeReworkService([_item(projectKey: 'pk1', boxName: 'BOX-9')]));
    await cache.refresh('Jamie', service: _FakeReworkService(const []));
    expect(cache.hasRework('pk1', 'BOX-9'), isFalse);
    expect(cache.lastError, isNull);
  });

  // A closure reaches PG only when the outbox drains (~30s, or much longer
  // offline). Until then PG still reports the request as OPEN, so without this
  // filter a just-submitted rework keeps its orange badge and the operator can
  // re-enter rework mode and be asked to redo work they already did.
  group('pending local closures', () {
    test('items with a queued closure are filtered out', () async {
      await cache.refresh(
        'Jamie',
        service: _FakeReworkService([
          _item(projectKey: 'pk1', boxName: 'BOX-9', folderSeq: 2, imageName: 'a.jpg'),
          _item(projectKey: 'pk1', boxName: 'BOX-9', folderSeq: 2, imageName: 'b.jpg'),
        ]),
        alreadyClosedKeys: {'pk1|BOX-9|2|a.jpg'},
      );
      final items = cache.itemsForBox('pk1', 'BOX-9');
      expect(items.map((i) => i.imageName).toList(), ['b.jpg']);
    });

    test('a box whose every item is locally closed loses its badge', () async {
      await cache.refresh(
        'Jamie',
        service: _FakeReworkService([
          _item(projectKey: 'pk1', boxName: 'BOX-9', folderSeq: 2, imageName: 'a.jpg'),
        ]),
        alreadyClosedKeys: {'pk1|BOX-9|2|a.jpg'},
      );
      expect(cache.hasRework('pk1', 'BOX-9'), isFalse);
    });

    // The key is built from the same fields enqueueReworkClosed uses for its
    // outbox entity_key, so a mismatch in either would silently stop filtering.
    test('an unrelated key does not filter anything', () async {
      await cache.refresh(
        'Jamie',
        service: _FakeReworkService([
          _item(projectKey: 'pk1', boxName: 'BOX-9', folderSeq: 2, imageName: 'a.jpg'),
        ]),
        alreadyClosedKeys: {'pk1|BOX-9|3|a.jpg', 'pk2|BOX-9|2|a.jpg'},
      );
      expect(cache.hasRework('pk1', 'BOX-9'), isTrue);
    });
  });

  test('a blank username short-circuits without asking PG', () async {
    final service = _FakeReworkService(const []);
    await cache.refresh('   ', service: service);
    expect(service.calls, 0);
    expect(cache.lastRefreshed, isNull);
  });
}
