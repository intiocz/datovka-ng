/// Development window. It shows only the sample mailboxes in `demo_data.dart`
/// and does not open the real archive.
library;

import 'package:datovka/data/app_state.dart';
import 'package:datovka/data/gov_services.dart';
import 'package:datovka/main.dart';
import 'package:flutter/widgets.dart';

import 'demo_data.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadGovTemplates();
  runApp(
    DatovkaApp(
      state: AppState(
        autoSync: false,
        initialBoxes: demoBoxes,
        messages: demoMessages(),
        directory: demoDirectory,
      ),
    ),
  );
}
