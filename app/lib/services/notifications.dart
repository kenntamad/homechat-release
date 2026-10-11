import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Local notifications while the app is running (desktop, and Android in the
/// foreground). When the Android app is in the background, the server sends
/// pushes through ntfy instead.
class Notifications {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static void Function(String payload)? onTap;

  static Future<void> init() async {
    if (_ready) return;
    try {
      final android = AndroidInitializationSettings('@mipmap/ic_launcher');
      final darwin = DarwinInitializationSettings();
      final linux = LinuxInitializationSettings(defaultActionName: 'Open');
      final windows = WindowsInitializationSettings(
        appName: 'Home Chat',
        appUserModelId: 'Net.HomeChat.App',
        guid: '5f7c1c4e-8a2b-4b7e-9d3a-1c6f0e2b9a47',
      );
      await _plugin.initialize(
        InitializationSettings(android: android, iOS: darwin, macOS: darwin, linux: linux, windows: windows),
        onDidReceiveNotificationResponse: (r) {
          if (r.payload != null) onTap?.call(r.payload!);
        },
      );
      if (Platform.isAndroid) {
        await _plugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      }
      _ready = true;
    } catch (e) {
      // Notifications are a nice-to-have; never block the app on them.
      print('notifications unavailable: $e');
    }
  }

  static int _idFor(String key) => key.hashCode & 0x7fffffff;

  static Future<void> message({required String chatId, required String title, required String body}) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        _idFor(chatId),
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails('messages', 'Messages',
              importance: Importance.high, priority: Priority.high, category: AndroidNotificationCategory.message),
          macOS: DarwinNotificationDetails(),
          linux: LinuxNotificationDetails(),
        ),
        payload: 'chat:$chatId',
      );
    } catch (_) {}
  }

  static Future<void> call({required String callId, required String chatId, required String title, required String body}) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        _idFor('call'),
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails('calls', 'Calls',
              importance: Importance.max,
              priority: Priority.max,
              category: AndroidNotificationCategory.call,
              fullScreenIntent: true,
              ongoing: true,
              timeoutAfter: 45000),
          macOS: DarwinNotificationDetails(),
          linux: LinuxNotificationDetails(urgency: LinuxNotificationUrgency.critical),
        ),
        payload: 'chat:$chatId',
      );
    } catch (_) {}
  }

  static Future<void> cancelCall() async {
    if (!_ready) return;
    try {
      await _plugin.cancel(_idFor('call'));
    } catch (_) {}
  }

  static Future<void> clearChat(String chatId) async {
    if (!_ready) return;
    try {
      await _plugin.cancel(_idFor(chatId));
    } catch (_) {}
  }
}
