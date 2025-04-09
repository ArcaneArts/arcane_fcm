import 'package:arcane/arcane.dart';
import 'package:arcane_fcm/arcane_fcm.dart';
import 'package:serviced/serviced.dart';

/// The notification runner wraps around your widgets to grab context and register it to the notification service.
/// This is important to be at least once on every screen since to do anything in the app you need context so wrap every screen with
/// this widget anywhere so your notification handlers can get context.
class FCMRunner extends StatefulWidget {
  final Widget child;

  const FCMRunner(this.child, {super.key});

  @override
  State<FCMRunner> createState() => _FCMRunnerState();
}

class _FCMRunnerState extends State<FCMRunner> {
  ArcaneFCMService? _svc() =>
      services().services.values.whereType<ArcaneFCMService>().firstOrNull;

  @override
  void initState() {
    assert(
      _svc() != null,
      "NotificationService not found in active services! When registering your notification service, use lazy: false -> services().register<SVC>(() => SVC(), lazy: false)",
    );

    _svc()!.notificationQueueHandlers[identityHash.toString()] = handle;
    Future.delayed(
      Duration(milliseconds: 50),
      () => _svc()!.tryHandleNotificationQueue(),
    );
    super.initState();
  }

  @override
  void dispose() {
    _svc()!.notificationQueueHandlers.remove(identityHash.toString());
    super.dispose();
  }

  void handle() => _svc()!.handleNotificationQueue(context);

  @override
  Widget build(BuildContext context) => widget.child;
}
