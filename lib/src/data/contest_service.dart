import 'package:cloud_firestore/cloud_firestore.dart';

/// Соревнование менеджеров: цель по лидам за день и премия за её достижение.
///
/// Настройка одна на всю команду — config/contest. Порог правит только админ
/// (экран «Соревнование»), менеджеры видят его как факт дня.
class ContestService {
  ContestService({FirebaseFirestore? db}) : _db = db ?? FirebaseFirestore.instance;
  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> get _doc => _db.collection('config').doc('contest');

  /// Сколько лидов за день даёт премию. По умолчанию 50.
  ///
  /// Значение читается потоком, а не разово: админ меняет порог со своего
  /// телефона — у менеджеров цифра и прогресс обновляются сразу, без
  /// перезахода в приложение.
  Stream<int> watchGoal() => _doc.snapshots().map((s) {
        final v = s.data()?['dailyGoal'];
        final n = v is num ? v.toInt() : 50;
        // Ноль и отрицательные значения сделали бы прогресс бессмысленным
        // (деление на ноль), поэтому нижняя граница — 1.
        return n < 1 ? 1 : n;
      });

  Future<void> setGoal(int value) => _doc.set(
        {'dailyGoal': value < 1 ? 1 : value, 'updatedAt': FieldValue.serverTimestamp()},
        SetOptions(merge: true),
      );

  /// Сколько лидов за неделю даёт премию. По умолчанию 300.
  ///
  /// Отдельное число, а не «дневная цель × 7»: неделя — это не семь ровных
  /// дней, в выходные поток другой, и владелец ставит недельную планку сам.
  Stream<int> watchWeekGoal() => _doc.snapshots().map((s) {
        final v = s.data()?['weeklyGoal'];
        final n = v is num ? v.toInt() : 300;
        return n < 1 ? 1 : n;
      });

  Future<void> setWeekGoal(int value) => _doc.set(
        {'weeklyGoal': value < 1 ? 1 : value, 'updatedAt': FieldValue.serverTimestamp()},
        SetOptions(merge: true),
      );

  /// Командная премия за месяц. По умолчанию 1200.
  Stream<int> watchMonthGoal() => _doc.snapshots().map((s) {
        final v = s.data()?['monthlyGoal'];
        final n = v is num ? v.toInt() : 1200;
        return n < 1 ? 1 : n;
      });

  Future<void> setMonthGoal(int value) => _doc.set(
        {'monthlyGoal': value < 1 ? 1 : value, 'updatedAt': FieldValue.serverTimestamp()},
        SetOptions(merge: true),
      );

  /// Личные премии: у каждого менеджера СВОЯ планка, отдельно от командной.
  ///
  /// personalDaily/personalWeekly — планка «по умолчанию» для всех;
  /// personalByUid — индивидуальные исключения (новичку планку ниже,
  /// звезде — выше). Пустое исключение = менеджер живёт по общей планке.
  Stream<PersonalGoals> watchPersonalGoals() => _doc.snapshots().map((s) {
        final d = s.data() ?? {};
        int num_(Object? v, int def) {
          final n = v is num ? v.toInt() : def;
          return n < 1 ? 1 : n;
        }

        final by = <String, ({int? daily, int? weekly, int? monthly})>{};
        final raw = d['personalByUid'];
        if (raw is Map) {
          for (final e in raw.entries) {
            final v = e.value;
            if (v is! Map) continue;
            final daily = v['daily'] is num ? (v['daily'] as num).toInt() : null;
            final weekly = v['weekly'] is num ? (v['weekly'] as num).toInt() : null;
            final monthly = v['monthly'] is num ? (v['monthly'] as num).toInt() : null;
            if (daily != null || weekly != null || monthly != null) {
              by['${e.key}'] = (daily: daily, weekly: weekly, monthly: monthly);
            }
          }
        }
        return PersonalGoals(
          daily: num_(d['personalDaily'], 10),
          weekly: num_(d['personalWeekly'], 60),
          monthly: num_(d['personalMonthly'], 250),
          byUid: by,
        );
      });

  /// Общая личная планка (день/неделя).
  Future<void> setPersonalDefaults({int? daily, int? weekly, int? monthly}) => _doc.set(
        {
          if (daily != null) 'personalDaily': daily < 1 ? 1 : daily,
          if (weekly != null) 'personalWeekly': weekly < 1 ? 1 : weekly,
          if (monthly != null) 'personalMonthly': monthly < 1 ? 1 : monthly,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

  /// Индивидуальная планка менеджера. Все поля null — вернуть к общей.
  Future<void> setPersonalFor(String uid, {int? daily, int? weekly, int? monthly}) => _doc.set(
        {
          'personalByUid': {
            uid: daily == null && weekly == null && monthly == null
                ? FieldValue.delete()
                : {
                    if (daily != null) 'daily': daily < 1 ? 1 : daily,
                    if (weekly != null) 'weekly': weekly < 1 ? 1 : weekly,
                    if (monthly != null) 'monthly': monthly < 1 ? 1 : monthly,
                  },
          },
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
}

/// Личные планки премий: общая по умолчанию + индивидуальные исключения.
class PersonalGoals {
  const PersonalGoals({required this.daily, required this.weekly, required this.monthly, required this.byUid});
  final int daily;
  final int weekly;
  final int monthly;
  final Map<String, ({int? daily, int? weekly, int? monthly})> byUid;

  int dailyFor(String uid) => byUid[uid]?.daily ?? daily;
  int weeklyFor(String uid) => byUid[uid]?.weekly ?? weekly;
  int monthlyFor(String uid) => byUid[uid]?.monthly ?? monthly;

  static const def = PersonalGoals(daily: 10, weekly: 60, monthly: 250, byUid: {});
}
