import 'package:flutter/services.dart';

/// Тактильный отклик одним набором на всё приложение.
///
/// Нажатия закрывает PressScale, здесь — отклик на РЕЗУЛЬТАТ: отправилось,
/// сохранилось, не получилось. На телефоне это половина ощущения «сделано
/// качественно», а руке не нужно смотреть на экран, чтобы понять исход.
class Haptics {
  const Haptics._();

  /// Обычное действие: отправка, переключение, выбор из списка.
  static void tap() => HapticFeedback.lightImpact();

  /// Точка выбора: свайп «сцепился», элемент выделился.
  static void select() => HapticFeedback.selectionClick();

  /// Получилось: запись сохранена, рассылка принята.
  static void success() => HapticFeedback.mediumImpact();

  /// Не получилось: сообщение не ушло, форма не сохранилась.
  static void error() => HapticFeedback.heavyImpact();
}
