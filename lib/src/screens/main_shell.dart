import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../theme/app_theme.dart';
import 'broadcast_screen.dart';
import 'conversations_screen.dart';
import 'firebase_chats.dart';
import 'leads_screen.dart';
import 'settings_screen.dart';
import 'vip_clients_screen.dart';

/// Корневой каркас с нижней навигацией: Чаты · Лиды · VIP · Рассылка · Настройки.
class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Вкладка «Чаты» зависит от backend: firebase → Firestore-чаты.
    final isFirebase = ref.watch(appConfigProvider).isFirebase;
    final pages = [
      isFirebase ? const FirebaseConversationsScreen() : const ConversationsScreen(),
      const LeadsScreen(),
      const VipClientsScreen(),
      const BroadcastScreen(),
      const SettingsScreen(),
    ];
    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          indicatorColor: AppColors.brand.withValues(alpha: 0.16),
          labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => TextStyle(
              fontSize: 11.5,
              fontWeight: states.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
              color: states.contains(WidgetState.selected) ? AppColors.brand : null,
            ),
          ),
          iconTheme: WidgetStateProperty.resolveWith(
            (states) => IconThemeData(color: states.contains(WidgetState.selected) ? AppColors.brand : null),
          ),
        ),
        child: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          height: 66,
          backgroundColor: dark ? const Color(0xFF12191E) : Colors.white,
          surfaceTintColor: Colors.transparent,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.forum_outlined), selectedIcon: Icon(Icons.forum_rounded), label: 'Чаты'),
            NavigationDestination(icon: Icon(Icons.bolt_outlined), selectedIcon: Icon(Icons.bolt), label: 'Лиды'),
            NavigationDestination(icon: Icon(Icons.workspace_premium_outlined), selectedIcon: Icon(Icons.workspace_premium_rounded), label: 'VIP'),
            NavigationDestination(icon: Icon(Icons.campaign_outlined), selectedIcon: Icon(Icons.campaign_rounded), label: 'Рассылка'),
            NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings_rounded), label: 'Настройки'),
          ],
        ),
      ),
    );
  }
}
