// Превью-режим для скриншотов дизайна: экраны Лиды/VIP на фейковом Firestore,
// без Firebase и без логина. Запуск:
//   flutter build ios --simulator --target=lib/dev_preview.dart
//   SIMCTL_CHILD_PREVIEW_SCREEN=vip xcrun simctl launch <udid> <bundleId>
// НЕ используется в продакшен-сборке (main.dart его не импортирует).
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/config/app_config.dart';
import 'src/data/firebase_manager_service.dart';
import 'src/data/firestore_chat_repository.dart';
import 'src/data/lead_repository.dart';
import 'src/data/massage_repository.dart';
import 'src/data/presence_service.dart';
import 'src/data/quick_replies_service.dart';
import 'src/data/vip_repository.dart';
import 'src/design/design.dart';
import 'src/screens/analytics_screen.dart';
import 'src/data/contest_service.dart';
import 'src/data/voice_controller.dart';
import 'src/screens/contest_screen.dart';
import 'src/screens/leads_screen.dart';
import 'src/screens/firebase_chats.dart';
import 'src/screens/massage_screen.dart';
import 'src/screens/vip_clients_screen.dart';
import 'src/state/providers.dart';
import 'src/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = FakeFirebaseFirestore();
  final now = DateTime.now();
  DateTime at(int dayOff, int h, [int m = 0]) =>
      DateTime(now.year, now.month, now.day).add(Duration(days: dayOff, hours: h, minutes: m));

  Future<void> lead(int n, String name, String phone, int dayOff, String time, num? prep) =>
      db.collection('leads').add({
        'leadNumber': n,
        'name': name,
        'phone': phone,
        'appointmentDate': Timestamp.fromDate(at(dayOff, 12)),
        'appointmentTime': time,
        'prepayment': ?prep,
        'archived': false,
        'createdAt': Timestamp.fromDate(at(dayOff, 9 + n % 8, (n * 7) % 60)),
      });

  await lead(218, 'Ринат', '79058962500', 0, '15:00', 50000);
  await lead(217, 'Алия', '77014421180', 0, '16:30', null);
  await lead(216, 'Данияр', '77773100090', 0, '18:00', 100000);
  await lead(215, 'Мария', '79261234567', -1, '11:30', 30000);
  await lead(214, 'Асель', '77052223344', -1, '14:00', 25000);

  // ── Данные для превью «Конкурс» ──────────────────────────────────────────
  // Пять менеджеров и разное число сегодняшних лидов у каждого: нужно, чтобы
  // на скриншоте были видны и пьедестал, и список «остальных», и своя строка.
  for (final m in [
    ('u1', 'Гульсана'),
    ('u2', 'Гульнара'),
    ('u3', 'Алия'),
    ('u4', 'Akylbek'),
    ('u5', 'TIma'),
  ]) {
    await db.collection('users').doc(m.$1).set({'name': m.$2, 'role': 'manager', 'isActive': true});
  }
  await db.collection('config').doc('contest').set({'dailyGoal': 30, 'personalDaily': 5});
  var contestSeq = 500;
  Future<void> contestLead(String uid) => db.collection('leads').add({
        'leadNumber': contestSeq++,
        'name': 'Клиент $contestSeq',
        'phone': '7700000\$contestSeq',
        'archived': false,
        'createdBy': uid,
        'createdAt': Timestamp.fromDate(at(0, 10, contestSeq % 60)),
      });
  for (final e in [('u2', 9), ('u1', 7), ('u3', 5), ('u4', 3), ('u5', 1)]) {
    for (var i = 0; i < e.$2; i++) {
      await contestLead(e.$1);
    }
  }

  Future<void> vip(String name, String phone, String city, int dayOff, String status) =>
      db.collection('clients').add({
        'name': name,
        'phone': phone,
        'city': city,
        'arrivalDate': Timestamp.fromDate(at(dayOff + 1, 8)),
        'status': status,
        'archived': false,
        'createdAt': Timestamp.fromDate(at(dayOff, 11)),
      });

  await vip('Владимир', '79151112233', 'Москва', 0, 'inTreatment');
  await vip('Гульнара', '77012223311', 'Алматы', 0, 'inHotel');
  await vip('Сергей', '79263334455', 'Казань', -1, 'awaitingArrival');
  await vip('Айгерим', '77774445566', 'Астана', -1, 'departed');

  // Рабочие сессии для превью экрана аналитики менеджера.
  Future<void> session(int dayOff, int h1, int m1, int h2, int m2, {bool ongoing = false}) =>
      db.collection('workSessions').add({
        'uid': 'u1',
        'name': 'Айгерим',
        'startAt': Timestamp.fromDate(at(dayOff, h1, m1)),
        'lastActiveAt': Timestamp.fromDate(ongoing ? DateTime.now() : at(dayOff, h2, m2)),
        'endAt': ongoing ? null : Timestamp.fromDate(at(dayOff, h2, m2)),
      });

  await session(0, 9, 2, 12, 15);
  await session(0, 13, 5, 0, 0, ongoing: true);
  await session(-1, 8, 55, 13, 10);
  await session(-1, 14, 0, 19, 12);
  await session(-1, 21, 30, 22, 5);
  await session(-2, 10, 20, 18, 40);
  await session(-4, 9, 0, 11, 30);
  await session(-4, 16, 15, 20, 45);

  Future<void> mass(int n, String name, String phone, int dayOff, String time, num? prep) =>
      db.collection('massages').add({
        'massageNumber': n,
        'name': name,
        'phone': phone,
        'appointmentDate': Timestamp.fromDate(at(dayOff, 12)),
        'appointmentTime': time,
        'prepayment': ?prep,
        'archived': false,
        'createdAt': Timestamp.fromDate(at(dayOff, 9 + n % 8, (n * 7) % 60)),
      });

  await mass(31, 'Гульмира', '77012223344', 0, '10:00', 15000);
  await mass(32, 'Ирина', '79161234567', 0, '12:30', null);
  await mass(33, 'Асхат', '77775554433', -1, '17:00', 20000);

  // Переписка со всеми типами пузырей: текст, фото, голосовое, файл, видео,
  // ответ на сообщение, удалённое.
  const chatId = 'tg_777';
  await db.collection('conversations').doc(chatId).set({
    'name': '+77015554433',
    'phone': '77015554433',
    'lastMessageAt': Timestamp.fromDate(at(0, 18, 40)),
    'unreadCount': 0,
  });

  // Ещё несколько диалогов с именами разной длины — проверка выравнивания
  // времени в списке чатов.
  Future<void> conv(String id, String name, String? phone, String preview, int minute, {int unread = 0}) =>
      db.collection('conversations').doc(id).set({
        'name': name,
        'phone': ?phone,
        'lastMessagePreview': preview,
        'lastMessageAt': Timestamp.fromDate(at(0, 17, minute)),
        'unreadCount': unread,
        'lastOutbound': unread == 0,
        'lastAuthorName': unread == 0 ? 'Гульнара' : null,
      });

  await conv('tg_1', '👀👀', null, 'Спасибо за обращение!', 55);
  await conv('tg_2', '+7 747 319-30-61', '77473193061', 'Голосовое', 50);
  await conv('tg_3', 'Құндызай', null, 'Хорошо. Благодарю))', 45, unread: 1);
  await conv('tg_4', 'Роман Палкин', null, 'Здравствуйте!', 40);
  await conv('tg_5', 'Ольга Алейникова(Дерипаско)', null, 'Здравствуйте!', 35);

  // Шаблоны быстрых ответов — для проверки окна подтверждения.
  Future<void> qr(String title, String text) => db.collection('quickReplies').add({
        'title': title,
        'text': text,
        'createdAt': Timestamp.fromDate(at(0, 9)),
      });
  await qr('Астана', 'Центр остеопатии Dr. Toitayev\nГород Астана Калдаякова 13\nhttps://2gis.kz/astana/geo/70000001115102649');
  await qr('Прайс', 'Информация о приёме\nПриём проводится только по предварительной записи.\n\nСтоимость процедуры — 95 000 ₸.');
  await qr('Расписание', 'Расписание, город Астана:\n\n• АВГУСТ: 17–20, 24–27, 30–31\n• СЕНТЯБРЬ: 1–3, 6–10');

  var msgNo = 0;
  Future<void> msg(
    String direction,
    String type, {
    String? text,
    String? mediaUrl,
    String? fileName,
    String? contentType,
    String? replyToText,
    String status = 'read',
    String? authorId,
    bool deleted = false,
    int minute = 0,
  }) {
    msgNo++;
    return db.collection('messages').doc('m$msgNo').set({
      'conversationId': chatId,
      'direction': direction,
      'type': type,
      'text': ?text,
      'mediaUrl': ?mediaUrl,
      'fileName': ?fileName,
      'mediaContentType': ?contentType,
      'replyToText': ?replyToText,
      'status': status,
      'authorId': ?authorId,
      'isDeleted': deleted,
      'createdAt': Timestamp.fromDate(at(0, 18, minute)),
    });
  }

  await msg('inbound', 'text', text: 'Здравствуйте! Хочу записаться на массаж', minute: 2);
  await msg('outbound', 'text',
      text: 'Здравствуйте! Подскажите город и что вас беспокоит?', authorId: 'auto', minute: 3);
  await msg('inbound', 'text', text: 'Алматы, боли в шее', minute: 5);
  await msg('inbound', 'audio', mediaUrl: 'https://download.samplelib.com/mp3/sample-9s.mp3', minute: 6);
  await msg('inbound', 'image', mediaUrl: 'https://picsum.photos/id/1027/900/1200', minute: 7);
  await msg('inbound', 'image',
      mediaUrl: 'https://picsum.photos/id/1015/1200/800', text: 'Вот снимок МРТ', minute: 8);
  await msg('inbound', 'document',
      mediaUrl: 'https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf',
      fileName: 'Заключение_МРТ_шейный.pdf',
      contentType: 'application/pdf',
      minute: 9);
  await msg('outbound', 'text',
      text: 'Спасибо, получили!', replyToText: 'Заключение_МРТ_шейный.pdf', authorId: 'u1', minute: 10);
  await msg('outbound', 'audio',
      mediaUrl: 'https://download.samplelib.com/mp3/sample-12s.mp3', authorId: 'u1', minute: 11);
  await msg('inbound', 'video', mediaUrl: 'https://download.samplelib.com/mp4/sample-5s.mp4', minute: 12);
  await msg('outbound', 'text', text: 'Ок', authorId: 'u1', status: 'delivered', minute: 13);
  await msg('outbound', 'text', text: 'Удалённое', authorId: 'u1', deleted: true, minute: 14);
  await msg('outbound', 'text',
      text: 'Записал вас на завтра в 15:00, ждём вас в клинике!', authorId: 'u1', status: 'queued', minute: 15);
  // Вложения в момент отправки (локальный путь вместо ссылки) — проверка
  // мгновенных пузырей: голосовое и файл, которые ещё грузятся.
  await msg('outbound', 'audio', mediaUrl: '/tmp/voice_local.m4a', authorId: 'u1', status: 'sending', minute: 16);
  await msg('outbound', 'document',
      mediaUrl: '/tmp/schet.pdf', fileName: 'Счёт_на_оплату.pdf', authorId: 'u1', status: 'sending', minute: 17);

  // Приоритет у переменной окружения (SIMCTL_CHILD_PREVIEW_SCREEN) — можно
  // переключать экран без пересборки; --dart-define как запасной вариант.
  const fromDefine = String.fromEnvironment('PREVIEW_SCREEN');
  final fromEnv = Platform.environment['PREVIEW_SCREEN'] ?? '';
  final screen = fromEnv.isNotEmpty ? fromEnv : (fromDefine.isNotEmpty ? fromDefine : 'leads');
  // Автопроверка плеера голосовых: через 4 секунды превью само жмёт play —
  // на скриншоте видно паузу, прогресс и панель «сейчас играет».
  if (screen == 'chat') {
    Future.delayed(const Duration(seconds: 4), () {
      VoiceController.I.toggle('https://download.samplelib.com/mp3/sample-12s.mp3');
    });
  }
  runApp(
    ProviderScope(
      overrides: [
        leadRepositoryProvider.overrideWithValue(LeadRepository(firestore: db)),
        massageRepositoryProvider.overrideWithValue(MassageRepository(firestore: db)),
        vipRepositoryProvider.overrideWithValue(VipRepository(firestore: db)),
        firestoreChatRepositoryProvider.overrideWithValue(FirestoreChatRepository(db: db)),
        firebasePresenceServiceProvider.overrideWithValue(FirebasePresenceService(db: db)),
        quickRepliesServiceProvider.overrideWithValue(QuickRepliesService(db: db)),
        contestServiceProvider.overrideWithValue(ContestService(db: db)),
        firebaseManagerServiceProvider.overrideWithValue(FirebaseManagerService(db: db)),
        appConfigProvider.overrideWithValue(
          AppConfig(apiBaseUrl: '', realtimeUrl: '', userId: 'u1', userName: 'Гульсана'),
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: screen == 'chat' ? buildIosTheme(Brightness.light, AppSkin.ocean) : buildAppTheme(Brightness.light),
        home: switch (screen) {
          'contest' => const ContestScreen(),
          'vip' => const VipClientsScreen(),
          'manager' => ManagerDetailScreen(uid: 'u1', name: 'Айгерим', db: db),
          'massage' => const MassageScreen(),
          'photo' => const PhotoViewerPage(url: 'https://picsum.photos/900/1400'),
          'chats' => const FirebaseConversationsScreen(),
          'chat' => FirebaseChatScreen(
              conversation: FsConversation(
                id: chatId,
                name: '+77015554433',
                phone: '77015554433',
                preview: null,
                lastMessageAt: at(0, 18, 15),
                unreadCount: 0,
              ),
            ),
          _ => const LeadsScreen(),
        },
      ),
    ),
  );
}
