import 'package:flutter_test/flutter_test.dart';
import 'package:qishui_player/core/models.dart';
import 'package:qishui_player/core/session.dart';
import 'package:shared_preferences/shared_preferences.dart';

Track _track(String id) => Track(
      id: id,
      title: '曲$id',
      artist: '艺人',
      album: '专辑',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlaySession', () {
    test('save/load 往返保留队列、索引、模式与进度', () async {
      SharedPreferences.setMockInitialValues({});
      await PlaySession.save(
        tracks: [_track('a'), _track('b'), _track('c')],
        index: 1,
        playMode: 'shuffle',
        positionMs: 65000,
      );
      final session = await PlaySession.load();
      expect(session, isNotNull);
      expect(session!.tracks.length, 3);
      expect(session.tracks[1].id, 'b');
      expect(session.index, 1);
      expect(session.playMode, 'shuffle');
      expect(session.positionMs, 65000);
    });

    test('超长队列以当前曲为中心开窗，索引平移', () async {
      SharedPreferences.setMockInitialValues({});
      final tracks = List<Track>.generate(900, (i) => _track(i.toString()));
      await PlaySession.save(
        tracks: tracks,
        index: 800,
        playMode: 'sequence',
        positionMs: 0,
      );
      final session = await PlaySession.load();
      expect(session!.tracks.length, 500);
      expect(session.tracks[session.index].id, '800');
    });

    test('索引越界时夹取到合法区间；未知模式回退 sequence', () async {
      SharedPreferences.setMockInitialValues({
        'playSession':
            '{"tracks":[{"id":"x","title":"t","artist":"","album":""}],"index":9,"playMode":"weird","positionMs":-5}',
      });
      final session = await PlaySession.load();
      expect(session!.index, 0);
      expect(session.playMode, 'sequence');
      expect(session.positionMs, -5); // 原样保留，播放层负责夹取
    });

    test('损坏 JSON / 空队列为 null；clear 后为 null', () async {
      SharedPreferences.setMockInitialValues({'playSession': '{oops'});
      expect(await PlaySession.load(), isNull);
      SharedPreferences.setMockInitialValues({
        'playSession': '{"tracks":[],"index":0,"playMode":"sequence"}',
      });
      expect(await PlaySession.load(), isNull);
      SharedPreferences.setMockInitialValues({});
      await PlaySession.save(
          tracks: [_track('a')], index: 0, playMode: '', positionMs: 0);
      await PlaySession.clear();
      expect(await PlaySession.load(), isNull);
    });
  });

  group('Track 模型', () {
    test('fromJson 对缺失/异型字段容错', () {
      final track = Track.fromJson({});
      expect(track.id, '');
      expect(track.durationSeconds, 0);
      expect(track.vip, isFalse);
      final vip = Track.fromJson({'id': 42, 'vip': true, 'durationSeconds': '61'});
      expect(vip.id, '42');
      expect(vip.durationSeconds, 61);
      expect(vip.vip, isTrue);
    });

    test('toJson/fromJson 往返', () {
      final track = Track(
          id: 'i', title: 't', artist: 'a', album: 'b', vip: true,
          durationSeconds: 30, cover: 'http://c', artistId: 'ar', albumId: 'al');
      expect(Track.fromJson(track.toJson()).toJson(), track.toJson());
    });

    test('durationLabel 格式', () {
      expect(_track('a').durationLabel, '--:--');
      expect(
        const Track(id: '', title: '', artist: '', album: '', durationSeconds: 75)
            .durationLabel,
        '1:15',
      );
    });
  });
}
