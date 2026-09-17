import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

/// Управление менеджерами в firebase-режиме: список из Firestore users,
/// создание/изменение через Cloud Functions (createManager/updateManager).
class FirebaseManagerService {
  FirebaseManagerService({FirebaseFirestore? db, FirebaseFunctions? functions})
      : _db = db ?? FirebaseFirestore.instance,
        _injectedFunctions = functions;

  final FirebaseFirestore _db;
  final FirebaseFunctions? _injectedFunctions;

  // Лениво: в превью-сборке (fake Firestore, без Firebase.initializeApp)
  // обращение к FirebaseFunctions в конструкторе роняло запуск.
  FirebaseFunctions? _cachedFunctions;
  FirebaseFunctions get _functions =>
      _injectedFunctions ?? (_cachedFunctions ??= FirebaseFunctions.instanceFor(region: 'europe-west1'));

  Stream<List<Map<String, dynamic>>> watchManagers() {
    return _db.collection('users').snapshots().map(
          (s) => s.docs.map((d) => {'id': d.id, ...d.data()}).toList(),
        );
  }

  Future<void> create({required String email, required String name, required String password, required String role}) async {
    await _functions.httpsCallable('createManager').call<Map<String, dynamic>>({
      'email': email,
      'name': name,
      'password': password,
      'role': role,
    });
  }

  Future<void> update(String uid, Map<String, dynamic> patch) async {
    await _functions.httpsCallable('updateManager').call<Map<String, dynamic>>({'uid': uid, ...patch});
  }
}
