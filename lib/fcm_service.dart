import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:arcane/arcane.dart';
import 'package:arcane_auth/arcane_auth.dart';
import 'package:arcane_fcm/arcane_fcm.dart';
import 'package:arcane_fcm_models/arcane_fcm_models.dart';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:fast_log/fast_log.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:serviced/serviced.dart';

const int _expirationTome = 1000 * 60 * 60 * 24 * 30;

abstract class ArcaneFCMService<N extends ArcaneFCMMessage>
    extends StatelessService
    implements AsyncStartupTasked {
  late BaseDeviceInfo deviceInfo;
  FlutterLocalNotificationsPlugin fn = FlutterLocalNotificationsPlugin();
  DeviceInfoPlugin di = DeviceInfoPlugin();
  late bool notificationsAllowed;
  StreamSubscription<String>? fcmTokenRefreshSubscription;
  final Queue<N> notificationQueue = Queue();
  final Map<String, VoidCallback> notificationQueueHandlers = {};
  Map<Type, ArcaneFCMHandler<N>> notificationHandlers = {};

  Future<void> writeUserDevices(String user, List<FCMDeviceInfo> devices);

  Future<List<FCMDeviceInfo>> readUserDevices(String user);

  N notificationFromMap(Map<String, dynamic> map);

  Map<Type, ArcaneFCMHandler<N>> onRegisterNotificationHandlers();

  @override
  Future<void> onStartupTask() async {
    notificationHandlers.addAll(onRegisterNotificationHandlers());
    deviceInfo = await di.deviceInfo;
    verbose("Device Info ${deviceInfo.data}");
    await setupLocalNotifications();
    await setupFCMNotifications();
    fcmTokenRefreshSubscription = FirebaseMessaging.instance.onTokenRefresh
      .listen(registerToken)..onError((err) {
      error("Failed to receive update from FCM Token Refresh");
      error(err);
    });
  }

  Future<void> sendLocalNotification({
    required String title,
    required String body,
    required Map<String, dynamic> payload,
  }) async {
    await fn.show(
      0,
      title,
      body,
      NotificationDetails(
        android: const AndroidNotificationDetails(
          'notifications',
          'Notifications',
          channelDescription: 'Configure Notifications in Resilient',
          importance: Importance.max,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          interruptionLevel: InterruptionLevel.timeSensitive,
        ),
      ),
      payload: jsonEncode(payload),
    );
  }

  Future<void> setupFCMNotifications() async {
    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      announcement: false,
      badge: true,
      carPlay: false,
      criticalAlert: false,
      provisional: false,
      sound: true,
    );

    await FirebaseMessaging.instance
        .setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );

    FirebaseMessaging.onMessage.listen((i) {
      verbose("RECEIVE: ${i.notification?.title} ${i.data}");
    });

    FirebaseMessaging.onMessageOpenedApp.listen(receiveFCMNotificationResponse);
    RemoteMessage? tappedRemoteMessage =
        await FirebaseMessaging.instance.getInitialMessage();
    if (tappedRemoteMessage != null) {
      receiveFCMNotificationResponse(tappedRemoteMessage);
    }
  }

  Future<void> setupLocalNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('launcher_icon');
    const DarwinInitializationSettings initializationSettingsDarwin =
        DarwinInitializationSettings(
          requestSoundPermission: true,
          requestBadgePermission: true,
          requestAlertPermission: true,
        );
    const LinuxInitializationSettings initializationSettingsLinux =
        LinuxInitializationSettings(defaultActionName: 'Open Resilient');
    const WindowsInitializationSettings initializationSettingsWindows =
        WindowsInitializationSettings(
          appName: 'Resilient',
          appUserModelId: 'Com.Dexterous.FlutterLocalNotificationsExample',
          // Search online for GUID generators to make your own
          guid: 'be99a50a-d7c2-4381-9bc6-104ebb2999fd',
        );
    const InitializationSettings initializationSettings =
        InitializationSettings(
          android: initializationSettingsAndroid,
          iOS: initializationSettingsDarwin,
          macOS: initializationSettingsDarwin,
          linux: initializationSettingsLinux,
          windows: initializationSettingsWindows,
        );

    await fn.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: receiveLocalNotificationResponse,
    );
    info("Initialized Local Notifications Plugin");
    notificationsAllowed =
        ((await fn
                .resolvePlatformSpecificImplementation<
                  IOSFlutterLocalNotificationsPlugin
                >()
                ?.requestPermissions(alert: true, badge: true, sound: true)) ??
            false) ||
        ((await fn
                .resolvePlatformSpecificImplementation<
                  MacOSFlutterLocalNotificationsPlugin
                >()
                ?.requestPermissions(alert: true, badge: true, sound: true)) ??
            false) ||
        ((await fn
                .resolvePlatformSpecificImplementation<
                  AndroidFlutterLocalNotificationsPlugin
                >()
                ?.requestNotificationsPermission()) ??
            false);
    info("Notifications allowed: $notificationsAllowed");
  }

  Future<void> tryHandleNotificationQueue() async {
    if (!$signedIn || notificationQueueHandlers.isEmpty) {
      return;
    }

    for (VoidCallback i
        in notificationQueueHandlers.values.reversed().toList()) {
      try {
        verbose("Trying to handle notification queue with handler $i");
        i();
        return;
      } catch (e, es) {
        error("Failed to handle notification with handler: $i");
        error(e);
        error(es);
        continue;
      }
    }

    warn("No notification handlers were able to process the queue.");
  }

  Future<void> handleNotificationQueue(BuildContext context) async {
    if (!$signedIn) {
      warn("Can't handle notification queue because we're not signed in!");
      return;
    }

    while (notificationQueue.isNotEmpty) {
      N n = notificationQueue.removeFirst();
      verbose("Handling notification: ${n.runtimeType}");
      try {
        if (n.user != $uid) {
          warn("Notification is not for the current user. Ignoring.");
          continue;
        }

        await handleNotification(context, n);
        success("Handled notification: ${n.runtimeType}");
      } catch (e, es) {
        error("Failed to handle notification: ${n.runtimeType}");
        error(e);
        error(es);
      }
    }
  }

  Future<void> handleNotification(BuildContext context, N notification) async {
    ArcaneFCMHandler? h = notificationHandlers[notification.runtimeType];

    if (h == null) {
      error(
        "No Notification Handler found for type ${notification.runtimeType}. Register handler in NotificationService",
      );
      return;
    }

    verbose(
      "Using handler: ${h.runtimeType} for notification: ${notification.runtimeType}",
    );
    try {
      await h.handle(context, notification);
      success(
        "Successfully handled notification with handler: ${h.runtimeType}",
      );
    } catch (e, es) {
      error(
        "Failed to handle notification with handler: ${h.runtimeType}. Notification was ${notification.toMap()}",
      );
      error(e);
      error(es);
    }
  }

  void receiveNotificationResponse(String? payload) {
    if (payload != null) {
      verbose("Notification Payload Received: $payload");
      try {
        print(jsonDecode(jsonDecode(payload)["data"]));
        N n = notificationFromMap(jsonDecode(jsonDecode(payload)["data"]));

        if (n.runtimeType == N) {
          error(
            "Received a generic ${n.runtimeType}. This should not happen. You need to define a typed subclass for the notification. It should be a subclass.",
          );
        }

        notificationQueue.add(n);
        success("Added ${n.runtimeType} to the notification handler queue.");
      } catch (e, es) {
        error("Failed to decode notification: $payload");
        error(e);
        error(es);
      }
    } else {
      warn("Notification received without payload. Ignoring.");
    }

    Future.delayed(
      Duration(milliseconds: 250),
      () => tryHandleNotificationQueue(),
    );
  }

  void receiveFCMNotificationResponse(RemoteMessage message) {
    verbose("Opened FCM Notification: ${message.data}");
    receiveNotificationResponse(jsonEncode(message.data));
  }

  void receiveLocalNotificationResponse(
    NotificationResponse notificationResponse,
  ) {
    verbose("Received Local Notification: ${notificationResponse.payload}");
    receiveNotificationResponse(notificationResponse.payload);
  }

  Future<void> onBind() async {
    if (!await registerToken()) {
      warn("Failed to register FCM token on bind. Trying again next launch.");
      return;
    }

    await invalidateTokens();
  }

  Future<void> onUnbind() async {
    fn.cancelAll();
  }

  Future<void> onSignOut() async {
    fn.cancelAll();
    try {
      String? currentToken = await FirebaseMessaging.instance.getToken();
      if (currentToken == null) {
        info("No FCM token found for sign out.");
        return;
      }

      warn("Removing FCM Token");
      String hash = hashFCM(currentToken);
      List<FCMDeviceInfo> d = await readUserDevices($uid!);
      d.removeWhere((i) => i.hash == hash);
      await Future.wait([
        writeUserDevices($uid!, d),
        FirebaseMessaging.instance.deleteToken(),
      ], eagerError: false);

      success(
        "Successfully signed out token fcm & removed fcm tokens & hashes from user for this device.",
      );
    } catch (e, es) {
      error("Failed to sign out token fcm");
      error(es);
    }
  }

  Future<void> invalidateTokens() async {
    verbose("Invalidate Expired FCM Tokens started");
    List<String> removeHashes = [];
    List<String> removeDevices = [];
    List<FCMDeviceInfo> rd = await readUserDevices(
      $uid!,
    ).then((i) => i.toList());

    for (FCMDeviceInfo i in rd.toList()) {
      String hash = hashFCM(i.token);

      if (DateTime.timestamp().millisecondsSinceEpoch -
              i.createdAt.millisecondsSinceEpoch >
          _expirationTome) {
        rd.removeWhere((j) => j.hash == hash);
        verbose(
          "Invalidating FCM token for device: ${i.platform} with hash: $hash Expired!",
        );
        continue;
      }
    }

    await writeUserDevices($uid!, rd);
  }

  Future<bool> registerToken([String? newToken]) async {
    if (!$signedIn) {
      warn("Can't register FCM Token yet as we're not signed in!");
    }

    verbose("Register FCM Token started");

    String? currentToken =
        newToken ?? await FirebaseMessaging.instance.getToken();

    if (currentToken == null) {
      warn("Unable to obtain FCM token at this time! Will try next launch!");
      return false;
    }

    String hash = hashFCM(currentToken);
    List<FCMDeviceInfo> rd = await readUserDevices(
      $uid!,
    ).then((i) => i.toList());

    if (!rd.any((i) => hash == i.hash)) {
      info("Registering new FCM token for user");
      rd.add(
        FCMDeviceInfo(
          token: currentToken,
          hash: hash,
          platform:
              kIsWeb
                  ? "Web"
                  : Platform.isIOS
                  ? "iOS ${(deviceInfo as IosDeviceInfo).model} ${(deviceInfo as IosDeviceInfo).name}"
                  : Platform.isMacOS
                  ? "macOS ${(deviceInfo as MacOsDeviceInfo).model} ${(deviceInfo as MacOsDeviceInfo).computerName}"
                  : Platform.isAndroid
                  ? "Android ${(deviceInfo as AndroidDeviceInfo).model} ${(deviceInfo as AndroidDeviceInfo).name}"
                  : Platform.isWindows
                  ? "Windows ${(deviceInfo as WindowsDeviceInfo).productName} ${(deviceInfo as WindowsDeviceInfo).computerName}"
                  : Platform.isLinux
                  ? "Linux ${(deviceInfo as LinuxDeviceInfo).name} ${(deviceInfo as LinuxDeviceInfo).prettyName}"
                  : "Unknown ${hashFCM(jsonEncode(deviceInfo.data))}",
          createdAt: DateTime.timestamp(),
        ),
      );
      await writeUserDevices($uid!, rd);
      success("Registered new FCM token and updated user settings.");
    }

    return true;
  }
}

String hashFCM(String fcm) =>
    sha256.convert(utf8.encode("fcm:$fcm")).toString();
