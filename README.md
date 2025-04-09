Requires use of [arcane_fcm_models](https://pub.dev/packages/arcane_fcm_models) in your models to work. Read that first to make the models.

# FCMService
We need to implement an FCMService binding our notification model to the service. We also need to help the service read and write user devices.
```dart
import 'package:arcane_fcm/arcane_fcm.dart';
import 'package:arcane_fcm_models/arcane_fcm_models.dart';

// Our service extends the arcane fcm service
// We need to bind it to our root notification model
class MyNotificationService extends ArcaneFCMService<MyNotification> {
  // We need to implement the notificationFromMap method
  // Just deserialize the notification
  @override
  MyNotification notificationFromMap(Map<String, dynamic> map) =>
      MyNotificationMapper.fromMap(map);

  @override
  Map<Type, ArcaneFCMHandler> onRegisterNotificationHandlers() => const {
    // Bind the notification type to the handler for it.
    // See implementation of handler below.
    MyNotificationTaskReminder: TaskReminderNotificationHandler()
  }

  // Here, we need to grab our user devices
  // Since were using arcane_fluf, our capabilities are streamed live so we can just grab
  @override
  Future<List<FCMDeviceInfo>> readUserDevices(String user) async =>
      $capabilities.devices;

  // Here we need to write our user devices
  @override
  Future<void> writeUserDevices(String user, List<FCMDeviceInfo> devices) =>
      $capabilities.setSelfAtomic<MyUserCapabilities>(
            (i) => i!.copyWith(devices: devices),
      );
}
```

# Connecting the service
We need to tell the service when things happen in our app for this to work.
1. When the user service binds `await svc<NotificationService>().onBind();`
2. When the user signs out `await svc<NotificationService>().onSignOut();`
3. When the user service unbinds `await svc<NotificationService>().onUnbind();`

Make sure to connect those in fluf

# Notification Handlers
Notification handlers fire when a user taps a notification. The handler will fire if it launched the app, or if the app was in the background or if it was in the foreground.

```dart
// We need to extend ArcaneFCMHandler and bind it to our specific notification subclass we want to handle
class TaskReminderNotificationHandler
    extends ArcaneFCMHandler<MyNotificationTaskReminder> {
  // Add a const constructor so we only ever have one instance.
  const TaskReminderNotificationHandler();
  
  @override
  Future<void> handle(
    BuildContext context,
    MyNotificationTaskReminder notification,
  ) {
    // Do whatever when the user taps this notification
    // Here, we're using fire_crud to obtain the task reminder object based on the notification task id
    // Since its guaranteed that $user and $uid match notification.user, we can use $user.get
    TaskReminder? t = $user.get<TaskReminder>(notification.task);

    // Check if the task reminder isnt there
    if (t == null) {
      TextToast("Task not found").open(context);
      return;
    }

    // Otherwise open the task screen
    Sheet(
      builder:
          // Since were using pylon here, we add the task object we obtained to context
          (context) => Pylon<TaskReminder>(
            value: t!,
            // Then show the reminder screen!
            builder: (context) => TaskReminderScreen(),
          ),
    ).open(context);
  }
}
```