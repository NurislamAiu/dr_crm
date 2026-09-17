import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';

import 'firebase_options.dart';
import 'src/widgets/prank_host.dart';
import 'src/config/app_config.dart';
import 'src/data/push_service.dart';
import 'src/state/providers.dart';
import 'src/design/design.dart';
import 'src/screens/main_shell.dart';
import 'src/screens/login_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Firebase нужен для VIP-клиентов (Firestore). Защищённо: если проект ещё не
  // подключён (не запущен `flutterfire configure`), приложение всё равно
  // стартует — VIP-сохранение просто вернёт ошибку до настройки.
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (e) {
    debugPrint('[Firebase] init FAILED: $e — проверь flutterfire configure');
  }
  final config = await AppConfig.load();
  runApp(
    ProviderScope(
      overrides: [appConfigProvider.overrideWithValue(config)],
      child: const CrmApp(),
    ),
  );
}

class CrmApp extends ConsumerWidget {
  const CrmApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Скин акцента: смена перекрашивает приложение целиком.
    final skin = ref.watch(skinProvider);
    return MaterialApp(
      title: 'DR.TOITAYEV',
      navigatorKey: appNavigatorKey,
      debugShowCheckedModeBanner: false,
      theme: buildIosTheme(Brightness.light, skin),
      darkTheme: buildIosTheme(Brightness.dark, skin),
      // ЖЁСТКО СВЕТЛАЯ. Экраны списков (лиды, массаж, VIP, настройки) написаны
      // на зашитых светлых цветах и тему не читают вообще, а список чатов —
      // лишь частично. При системной тёмной теме это давало светлые карточки
      // на тёмном фоне и нечитаемый текст. Пока экраны не переведены на токены
      // темы, следовать настройке телефона нельзя — выглядит сломанным.
      themeMode: ThemeMode.light,
      // builder — НАД навигатором: сюда вешаются оверлеи (тосты, конфетти),
      // иначе они окажутся под открытыми поверх экранами.
      builder: (context, child) => MediaQuery(
        // Системный масштаб текста ограничен: плотные числовые блоки
        // и таб-бар ломаются на крупных значениях.
        data: MediaQuery.of(context).copyWith(
          textScaler: MediaQuery.textScalerOf(context).clamp(
            minScaleFactor: 0.9,
            maxScaleFactor: 1.25,
          ),
        ),
        // PrankHost — над навигатором: картинка-розыгрыш всплывает поверх
        // любого экрана и не трогает его состояние.
        child: PrankHost(child: child ?? const SizedBox.shrink()),
      ),
      home: const _Root(),
    );
  }
}

/// Гейт: без JWT-сессии — экран входа, иначе список диалогов.
class _Root extends ConsumerWidget {
  const _Root();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(appConfigProvider);
    return AnimatedBuilder(
      animation: config,
      builder: (context, _) {
        if (!config.isAuthenticated) {
          return const LoginScreen();
        }
        return const MainShell();
      },
    );
  }
}
