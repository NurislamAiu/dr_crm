import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// Розыгрыш: картинка на весь экран у выбранного менеджера.
///
/// Только картинка и только пока приложение открыто — ни звука, ни пушей.
/// Закрывается тапом и сама по таймеру. В документе остаётся, кто отправил:
/// шутка шуткой, но следы нужны.
class PrankItem {
  const PrankItem({required this.id, required this.url, required this.seconds, required this.at, this.from});

  /// Встроенная картинка из сборки: url == asset. Показывается мгновенно.
  static const asset = 'asset';

  bool get isAsset => url == asset;

  final String id;
  final String url;
  final int seconds;
  final DateTime at;
  final String? from;

  /// Свежий: старую шутку при открытии приложения показывать не надо.
  bool get isFresh => DateTime.now().difference(at) < const Duration(minutes: 2);

  static PrankItem? fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data();
    if (d == null) return null;
    final url = (d['url'] ?? '') as String;
    final at = (d['at'] as Timestamp?)?.toDate();
    if (url.isEmpty || at == null) return null;
    return PrankItem(
      id: (d['id'] ?? doc.id) as String,
      url: url,
      seconds: (d['seconds'] as num?)?.toInt() ?? 2,
      at: at,
      from: d['from'] as String?,
    );
  }
}

class PrankService {
  PrankService({FirebaseFirestore? db, FirebaseStorage? storage})
      : _db = db ?? FirebaseFirestore.instance,
        _storage = storage ?? FirebaseStorage.instance;

  final FirebaseFirestore _db;
  final FirebaseStorage _storage;

  DocumentReference<Map<String, dynamic>> get _config => _db.collection('config').doc('prank');

  /// Картинка по умолчанию: выбирается один раз, дальше розыгрыш — одна кнопка.
  Stream<String?> watchImage() => _config.snapshots().map((s) => s.data()?['imageUrl'] as String?);

  Future<String?> image() async => (await _config.get()).data()?['imageUrl'] as String?;

  /// Загрузить новую картинку и запомнить её как текущую.
  Future<String> setImage({required List<int> bytes, required String contentType}) async {
    final ref = _storage.ref('media/prank/${DateTime.now().millisecondsSinceEpoch}');
    await ref.putData(Uint8List.fromList(bytes), SettableMetadata(contentType: contentType));
    final url = await ref.getDownloadURL();
    await _config.set({'imageUrl': url, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    return url;
  }

  /// Показать картинку менеджеру. У каждого свой слот: новая шутка вытесняет
  /// старую, история не копится. url == PrankItem.asset — встроенная картинка.
  Future<void> send({required String uid, required String url, int seconds = 2, String? fromName}) {
    return _db.collection('pranks').doc(uid).set({
      'id': DateTime.now().microsecondsSinceEpoch.toRadixString(16),
      'url': url,
      'seconds': seconds.clamp(1, 10),
      'from': fromName,
      'at': FieldValue.serverTimestamp(),
    });
  }

  /// Свой слот розыгрыша (менеджер читает только себя).
  Stream<PrankItem?> watch(String uid) =>
      _db.collection('pranks').doc(uid).snapshots().map(PrankItem.fromDoc);
}
