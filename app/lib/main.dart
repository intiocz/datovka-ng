import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/app_state.dart';
import 'data/archive_location.dart';
import 'data/core_bridge.dart';
import 'data/data_folder.dart';
import 'data/gov_services.dart';
import 'theme.dart';
import 'ui/app_lock.dart';
import 'ui/app_scope.dart';
import 'ui/home.dart';
import 'ui/settings_dialog.dart';
import 'ui/zfo_drop.dart';

bool get _mobile =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android);

bool get _mac => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadGovTemplates();
  const devDir = String.fromEnvironment('DATOVKA_DATA_DIR');
  if (devDir.isNotEmpty) {
    CoreBridge.dataDir = devDir;
  } else if (_mac || _mobile) {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('dataDir');
    final restored = _mobile ? await DataFolder.restore() : null;
    final dir = await ArchiveLocation.resolve(saved: saved, restored: restored);
    if (dir == null || dir.isEmpty) {
      runApp(const _PickDataFolder());
      return;
    }
    CoreBridge.dataDir = dir;
    if (saved != dir) await prefs.setString('dataDir', dir);
    if (_mobile) {
      // An archive in iCloud Drive may not be on the phone yet.
      runApp(const _Loading('Stahuji archiv z iCloudu…'));
      await DataFolder.materialize(dir);
    }
  }
  await AppLock.load();
  runApp(DatovkaApp(state: AppState(core: CoreBridge.open())));
}

/// Shown while the archive is brought onto the phone.
class _Loading extends StatelessWidget {
  final String text;

  const _Loading(this.text);

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTheme(Brightness.light),
    darkTheme: buildTheme(Brightness.dark),
    home: Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(text),
          ],
        ),
      ),
    ),
  );
}

/// First start on a phone: choose the folder with the Datovka data.
class _PickDataFolder extends StatelessWidget {
  const _PickDataFolder();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: Builder(
        builder: (context) => Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Datovka NG',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Vyberte archiv zpráv, stejný jako na počítači. V Souborech je '
                    'na iCloud Drive: složka Datovka (původní Datovka propojená '
                    's iCloudem), nebo Dokumenty → Datovka NG → Archiv.datovka. '
                    'Potom se otevírá sám a zprávy se stahují stejně jako na počítači.',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Na Macu se archiv na iCloud Drive dostane v Nastavení → '
                    'Archiv → Přesunout archiv do Dokumentů.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: () async {
                      final dir = await FilePicker.getDirectoryPath();
                      if (dir == null) return;
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setString('dataDir', dir);
                      await DataFolder.remember(dir);
                      // main() brings the files from iCloud Drive first.
                      await main();
                    },
                    child: const Text('Vybrat archiv'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () async {
                      final dir = await ArchiveLocation.newOnPhone();
                      if (dir == null) return;
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setString('dataDir', dir);
                      await main();
                    },
                    child: const Text('Začít s novým archivem jen v telefonu'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DatovkaApp extends StatelessWidget {
  final AppState state;

  const DatovkaApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: MaterialApp(
        title: 'Datovka NG',
        debugShowCheckedModeBanner: false,
        navigatorKey: _navKey,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        locale: const Locale('cs'),
        supportedLocales: const [Locale('cs'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: AppLock(
          child: _Menus(
            state: state,
            child: const ZfoDrop(child: Home()),
          ),
        ),
      ),
    );
  }
}

/// Native macOS menu bar with Settings (⌘,); elsewhere the child as is.
class _Menus extends StatelessWidget {
  final AppState state;
  final Widget child;

  const _Menus({required this.state, required this.child});

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.macOS) return child;
    return PlatformMenuBar(
      menus: [
        PlatformMenu(
          label: 'Datovka NG',
          menus: [
            if (PlatformProvidedMenuItem.hasMenu(
              PlatformProvidedMenuItemType.about,
            ))
              const PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.about,
              ),
            PlatformMenuItemGroup(
              members: [
                PlatformMenuItem(
                  label: 'Nastavení…',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.comma,
                    meta: true,
                  ),
                  onSelected: () =>
                      showSettings(_navKey.currentContext ?? context, state),
                ),
              ],
            ),
            const PlatformMenuItemGroup(
              members: [
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.hide,
                ),
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.hideOtherApplications,
                ),
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.showAllApplications,
                ),
              ],
            ),
            const PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.quit,
            ),
          ],
        ),
        const PlatformMenu(
          label: 'Okno',
          menus: [
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.minimizeWindow,
            ),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.zoomWindow,
            ),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.toggleFullScreen,
            ),
          ],
        ),
      ],
      child: child,
    );
  }
}

final _navKey = GlobalKey<NavigatorState>();
