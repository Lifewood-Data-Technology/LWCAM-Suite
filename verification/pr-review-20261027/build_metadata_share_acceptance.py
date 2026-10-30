"""Extend the atomic/PG host; keep previous acceptance snapshots unchanged."""
from pathlib import Path

here = Path(__file__).resolve().parent
text = (here / 'atomic_live_acceptance.template').read_text(encoding='utf-8')
text = text.replace('  bool shareUnavailable = false;',
                    '  bool shareUnavailable = false;\n  int sourceProbes = 0;')
text = text.replace(
    'async => shareUnavailable ? const ReworkInput(FsProbe.unreachable,null) : ReworkInput(FsProbe.found, targets[item.imageName]);',
    "async { sourceProbes++; return shareUnavailable ? const ReworkInput(FsProbe.unreachable,null) : ReworkInput(FsProbe.found, targets[item.imageName]); }")
# Earlier tests simulated an old interrupted write by copying the bytes by hand.
# Make that legacy protocol explicit; modern writers persist beginApply first.
text = text.replace(
    "await h._reworkStaged['1.jpg']!.copy(target.path);",
    "await h._reworkStaged['1.jpg']!.copy(target.path);\n"
    "    final legacyIntent=File(p.join(h._reworkStaged['1.jpg']!.parent.path,'intent.json'));\n"
    "    final legacy=jsonDecode(await legacyIntent.readAsString()) as Map; legacy.remove('apply_protocol');\n"
    "    await legacyIntent.writeAsString(jsonEncode(legacy));")
pos = text.rfind('\n}')
text = text[:pos] + r'''
  test('metadata offline: normal Undo then submit never resolves the input share', () async {
    final h=await fixture();
    for(final item in List<ReworkItem>.from(h._reworkItems)) {
      await h._undoReworkResolution(item);
    }
    h._reworkMetadataFixed.addAll(['1.jpg','2.jpg']);
    h.shareUnavailable=true;
    await h._onSubmitReworkPressed();
    expect(h.sourceProbes,0);
    expect(h.writes,isEmpty);
    expect((await closure('pk|BOX|1|1.jpg'))!['rework_type'],'Metadata');
    expect((await closure('pk|BOX|2|2.jpg'))!['rework_type'],'Metadata');
    expect((await queued(db)).where((r)=>r.entity=='capture_folder_rework').length,2);
  });

  test('metadata offline: unapplied abandoned staging does not require the share', () async {
    final h=await fixture(sameFolder:true);
    for(final file in h._reworkStaged.values) { await file.delete(); }
    h._reworkStaged.clear(); h._reworkMetadataFixed.addAll(['1.jpg','2.jpg']);
    h.shareUnavailable=true;
    await h._onSubmitReworkPressed();
    expect(h.sourceProbes,0);
    expect((await closure('pk|BOX|1|1.jpg'))!['rework_type'],'Metadata');
    expect((await closure('pk|BOX|1|2.jpg'))!['rework_type'],'Metadata');
    expect(h.writes,isEmpty);
  });

  test('metadata offline: started replacement blocks sibling closure without probing the share', () async {
    final h=await fixture(sameFolder:true);
    await ColorReworkStore.beginApply('station',h.targets['1.jpg']!.path);
    await setReworkInProgress(h.targets['1.jpg']!.parent.path,true,requireReadable:true);
    h._reworkStaged.clear(); h._reworkMetadataFixed.addAll(['1.jpg','2.jpg']);
    h.shareUnavailable=true;
    await h._onSubmitReworkPressed();
    expect(h.sourceProbes,0);
    expect(await closure('pk|BOX|1|1.jpg'),isNull);
    expect(await closure('pk|BOX|1|2.jpg'),isNull);
    expect(await queued(db),isEmpty);
    expect(await reworkReadinessHeld(h.targets['1.jpg']!.parent.path),isTrue);
  });

  test('metadata mixed: successful recapture and metadata close together', () async {
    final h=await fixture(sameFolder:true);
    final item=h._reworkItems.firstWhere((i)=>i.imageName=='2.jpg');
    await h._undoReworkResolution(item);
    h._reworkMetadataFixed.add('2.jpg');
    await h._onSubmitReworkPressed();
    expect(h.sourceProbes,1);
    expect(h.writes,['1.jpg']);
    expect((await closure('pk|BOX|1|1.jpg'))!['rework_type'],'Recapture');
    expect((await closure('pk|BOX|1|2.jpg'))!['rework_type'],'Metadata');
    expect((await queued(db)).where((r)=>r.entity=='capture_folder_rework'),isEmpty);
    expect(await reworkReadinessHeld(h.targets['1.jpg']!.parent.path),isFalse);
  });

  test('metadata mixed: failed recapture cannot close its metadata sibling or reset QC', () async {
    final h=await fixture(sameFolder:true);
    await h._undoReworkResolution(h._reworkItems.firstWhere((i)=>i.imageName=='2.jpg'));
    h._reworkMetadataFixed.add('2.jpg');
    failBindingFor='1.jpg';
    await h._onSubmitReworkPressed();
    expect(await queued(db),isEmpty);
    expect(await reworkReadinessHeld(h.targets['1.jpg']!.parent.path),isTrue);
    failBindingFor=null;
    await h._onSubmitReworkPressed();
    expect((await closure('pk|BOX|1|1.jpg'))!['rework_type'],'Recapture');
    expect((await closure('pk|BOX|1|2.jpg'))!['rework_type'],'Metadata');
  });

  test('metadata mixed: unavailable recapture source cannot close its metadata sibling', () async {
    final h=await fixture(sameFolder:true);
    await h._undoReworkResolution(h._reworkItems.firstWhere((i)=>i.imageName=='2.jpg'));
    h._reworkMetadataFixed.add('2.jpg'); h.shareUnavailable=true;
    await h._onSubmitReworkPressed();
    expect(h.sourceProbes,1);
    expect(await queued(db),isEmpty);
    expect(h._reworkItems,hasLength(2));
    h.shareUnavailable=false;
    await h._onSubmitReworkPressed();
    expect((await closure('pk|BOX|1|1.jpg'))!['rework_type'],'Recapture');
    expect((await closure('pk|BOX|1|2.jpg'))!['rework_type'],'Metadata');
  });

  test('metadata safety: failed first marker write already has local applying evidence', () async {
    final h=await fixture(sameFolder:true);
    final target=h.targets['1.jpg']!;
    final marker=File(p.join(target.parent.path,kProcessingMarkerName));
    await marker.delete(); await Directory(marker.path).create();
    await h._onSubmitReworkPressed();
    expect(await ColorReworkStore.recoverApplying('station',target.path),isNotNull);
    expect(await queued(db),isEmpty);
    h._reworkStaged.clear(); h._reworkMetadataFixed.addAll(['1.jpg','2.jpg']);
    h.shareUnavailable=true;
    final probes=h.sourceProbes;
    await h._onSubmitReworkPressed();
    expect(h.sourceProbes,probes);
    expect(await queued(db),isEmpty);
  });

  test('metadata offline: committed generation with leftover intent does not strand the folder', () async {
    final h=await fixture(sameFolder:true);
    final staged=h._reworkStaged['1.jpg']!;
    final intent=File(p.join(staged.parent.path,'intent.json'));
    final old=jsonDecode(await intent.readAsString()) as Map; old['applying']=true;
    final second=h._reworkItems.firstWhere((i)=>i.imageName=='2.jpg');
    await h._undoReworkResolution(second); h._reworkMetadataFixed.add('2.jpg');
    await h._onSubmitReworkPressed();
    expect((await queued(db)).where((r)=>r.entity=='rework_logs'),hasLength(2));
    // Model a process exit after the SQLite commit, before deleting intent.
    await intent.writeAsString(jsonEncode(old));
    final again=_SubmitHarness(h._boxSession,h.auth,[second],h.targets);
    again._boxSession.reworkClosed.remove('2.jpg');
    again._reworkMetadataFixed.add('2.jpg'); again.shareUnavailable=true;
    await again._onSubmitReworkPressed();
    expect(again.sourceProbes,0);
    expect(again._reworkItems,isEmpty);
    expect((await closure('pk|BOX|1|2.jpg'))!['rework_type'],'Metadata');
  });

  test('metadata offline: actual PG receives CLOSED and PENDING from the offline-share submission', () async {
    final h=await fixture(); identify(h);
    for(final item in List<ReworkItem>.from(h._reworkItems)) { await h._undoReworkResolution(item); }
    h._reworkMetadataFixed.addAll(['1.jpg','2.jpg']); h.shareUnavailable=true;
    await h._onSubmitReworkPressed();
    expect(h.sourceProbes,0);
    final records=await queued(db);
    expect(records,hasLength(4));
    final (conn,sink)=await realPg();
    try {
      await sink.apply(records);
      expect((await conn.execute("SELECT count(*) FROM rework_logs WHERE rework_status='CLOSED' AND rework_type='Metadata'")).single[0],2);
      expect((await conn.execute("SELECT count(*) FROM capture_folders WHERE qc_status='PENDING'")).single[0],2);
    } finally { await sink.close(); }
  });

  test('final review: reopening a later QC request must not resurrect a committed recapture', () async {
    final h=await fixture(sameFolder:true);
    final first=h._reworkItems.firstWhere((i)=>i.imageName=='1.jpg');
    final second=h._reworkItems.firstWhere((i)=>i.imageName=='2.jpg');
    final staged=h._reworkStaged['1.jpg']!;
    final intent=File(p.join(staged.parent.path,'intent.json'));
    final old=jsonDecode(await intent.readAsString()) as Map; old['applying']=true;
    await h._undoReworkResolution(second); h._reworkMetadataFixed.add('2.jpg');
    await h._onSubmitReworkPressed();
    expect((await closure('pk|BOX|1|1.jpg'))!['rework_type'],'Recapture');
    // Crash after the SQLite closure committed, before intent removal. The old
    // outbox has drained; QC later returns this page for a metadata correction.
    await intent.writeAsString(jsonEncode(old));
    final raw=await db.getDatabase('station');
    await raw.delete('sync_outbox',where:"entity IN ('rework_logs','capture_folder_rework')");
    final again=_SubmitHarness(h._boxSession,h.auth,[first],h.targets);
    again._boxSession.reworkClosed.clear();
    // Same production recovery call/assignment as _loadReworkImages on entry.
    final recovered=await ColorReworkStore.recoverApplying('station',h.targets['1.jpg']!.path);
    if(recovered!=null) again._reworkStaged[first.imageName]=recovered;
    again._reworkMetadataFixed.add(first.imageName); again.shareUnavailable=true;
    await again._onSubmitReworkPressed();
    expect(again._reworkStaged,isEmpty);
    expect(again.sourceProbes,0);
    expect(again.writes,isEmpty);
    expect((await closure('pk|BOX|1|1.jpg'))!['rework_type'],'Metadata');
    expect(await h.targets['1.jpg']!.readAsBytes(),[1]);
  });
''' + text[pos:]
(here / 'metadata_share_acceptance.template').write_text(text, encoding='utf-8')
print('Generated metadata-share regressions plus all previous atomic/PG cases')
