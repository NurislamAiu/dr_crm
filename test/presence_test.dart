import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crm/src/data/presence_service.dart';

void main() {
  test('presence: протухший lastSeen не считается «в сети»', () async {
    final db = FakeFirebaseFirestore();
    final now = DateTime.now();
    await db.collection('presence').doc('u1').set({
      'name': 'Свежий',
      'online': true,
      'lastSeen': Timestamp.fromDate(now.subtract(const Duration(seconds: 20))),
    });
    // Приложение убили: online остался true, но lastSeen старше 2 минут.
    await db.collection('presence').doc('u2').set({
      'name': 'Закрыл приложение',
      'online': true,
      'lastSeen': Timestamp.fromDate(now.subtract(const Duration(minutes: 10))),
    });

    final list = await FirebasePresenceService(db: db).watch().first;
    expect(list.map((e) => e.uid).toList(), ['u1']);
  });

  test('presence: stop() снимает онлайн', () async {
    final db = FakeFirebaseFirestore();
    final svc = FirebasePresenceService(db: db);
    svc.start('u1', 'Айгерим');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect((await svc.watch().first).length, 1);

    svc.stop();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect((await svc.watch().first).isEmpty, true);
  });
}
