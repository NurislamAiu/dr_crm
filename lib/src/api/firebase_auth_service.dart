import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Профиль менеджера из Firestore users/{uid}.
class ManagerProfile {
  const ManagerProfile({required this.uid, required this.email, required this.name, required this.role, required this.isActive});
  final String uid;
  final String email;
  final String name;
  final String role;
  final bool isActive;

  bool get isAdmin => role == 'admin' || role == 'administrator';
}

/// Вход менеджеров через Firebase Auth + профиль/роль из Firestore.
/// Используется в «firebase»-режиме backend (миграция).
class FirebaseAuthService {
  FirebaseAuthService({FirebaseAuth? auth, FirebaseFirestore? db})
      : _auth = auth ?? FirebaseAuth.instance,
        _db = db ?? FirebaseFirestore.instance;

  final FirebaseAuth _auth;
  final FirebaseFirestore _db;

  User? get currentUser => _auth.currentUser;
  Stream<User?> authStateChanges() => _auth.authStateChanges();

  Future<User> signIn(String email, String password) async {
    final cred = await _auth.signInWithEmailAndPassword(email: email.trim(), password: password);
    if (cred.user == null) throw FirebaseAuthException(code: 'no-user', message: 'Не удалось войти');
    return cred.user!;
  }

  Future<void> signOut() => _auth.signOut();

  /// Профиль текущего пользователя (роль/имя). null — если нет users/{uid}.
  Future<ManagerProfile?> loadProfile() async {
    final u = _auth.currentUser;
    if (u == null) return null;
    final doc = await _db.collection('users').doc(u.uid).get();
    final d = doc.data();
    if (d == null) return null;
    return ManagerProfile(
      uid: u.uid,
      email: (d['email'] ?? u.email ?? '') as String,
      name: (d['name'] ?? '') as String,
      role: (d['role'] ?? 'manager') as String,
      isActive: d['isActive'] != false,
    );
  }
}
