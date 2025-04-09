import 'package:arcane/arcane.dart';
import 'package:arcane_fcm_models/arcane_fcm_models.dart';

abstract class ArcaneFCMHandler<N extends ArcaneFCMMessage> {
  const ArcaneFCMHandler();

  Future<void> handle(BuildContext context, N notification);
}
