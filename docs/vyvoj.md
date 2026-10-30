# Vývoj

## Požadavky

- Rust (stable) – `brew install rustup && rustup default stable`
- Flutter – `brew install --cask flutter`
- macOS/iOS: Xcode (`sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch`)
- Windows a Linux se sestavují na své platformě (nebo v CI).

## Testy

```sh
cargo test                       # jádro, FFI, CLI
cargo clippy
cd app && flutter analyze && flutter test
# test mostu Dart → Rust nad skutečnými daty v ~/.dsgui (jen čtení)
cd app && flutter test --dart-define=DATOVKA_FFI=$PWD/../target/release/libdatovka_ffi.dylib \
  test/core_bridge_test.dart
# všechny SOAP požadavky proti schématům ISDS (potřebuje xmllint)
DATOVKA_ISDS_XSD=reference/isds-docs cargo test -p datovka-core schema_check
# jen čtecí operace proti ostrému ISDS se schránkami z dsgui.conf (jméno a heslo)
DATOVKA_DIR=~/.dsgui DATOVKA_LIVE=1 cargo test -p datovka-core --test production -- --ignored --nocapture
```

Testy jádra používají vzorová ZFO z `reference/datovka-qt/tests/data` (když
složka existuje) a schéma databáze v `core/src/legacy/schema.sql`.

## Spuštění a sestavení (macOS)

```sh
scripts/run-macos.sh       # vývojové okno nad ukázkou v app/dev
scripts/build-macos.sh     # datovka-ng.app nad skutečným archivem
```

`scripts/run-macos.sh` spouští `app/dev/main.dart`. Ta ukáže jen ukázkové
schránky ze `app/dev/demo_data.dart` a k archivu v iCloudu ani k `~/.dsgui`
se nepřipojí. Nainstalovaná aplikace ten soubor neobsahuje.

Výstup Flutter buildu je mimo iCloud (`~/Library/Caches/datovka-build`, odkaz
`app/build`). iCloud k souborům v Dokumentech přidává rozšířené atributy,
na kterých selhává `codesign`.

## Další platformy

```sh
scripts/build-ios.sh --no-codesign   # iOS; jádro je staticky v Runner (DynamicLibrary.process)
scripts/build-android.sh             # Android APK do dist/ (cargo-ndk, NDK, JDK 21)
scripts/package-deb.sh <bundle> <verze> <výstup.deb> [amd64|arm64]
scripts/package-appimage.sh <bundle> <verze> <výstup.AppImage> [x86_64|aarch64]
```

Linux a Windows sestavuje CI (`.github/workflows/build.yml`, funguje i v Gitea
Actions; úloha `linux-arm` jen na GitHubu): jádro `cargo build -p datovka-ffi`,
aplikace `flutter build linux|windows`, knihovna jádra se přibalí vedle
spustitelného souboru. Flutter pro Linux na ARM se bere z gitu, oficiální
archiv pro ARM není.

## Příkazová řádka

```sh
cargo run -p datovka-cli -- accounts            # schránky a počty zpráv z ~/.dsgui
cargo run -p datovka-cli -- list UZIVATEL       # zprávy schránky
cargo run -p datovka-cli -- sync UZIVATEL       # stáhne nové zprávy (přihlásí se do ISDS)
cargo run -p datovka-cli -- find UZIVATEL text  # adresář schránek
cargo run -p datovka-cli -- show soubor.zfo     # obsah ZFO
```

## Ikona

Logo a ikony jsou ve složce `branding/` (barvy žlutá #F2B835, modrá #2D4E7C).
Z nich se berou `app/assets/icon/icon_full.png` (iOS, Android, web, Windows),
`icon_macos.png` a `icon_android_foreground.png`.
`cd app && dart run flutter_launcher_icons` je rozkopíruje do všech platforem.
Potom se ručně navržené velikosti zkopírují přímo: `branding/macos/AppIcon-*.png`
do `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png`,
`branding/windows/app.ico` do `windows/runner/resources/app_icon.ico`
a `branding/web/icon-192.png`, `icon-512.png` do `web/icons/`.
Logo vlevo nahoře kreslí `_Mark` v `app/lib/ui/sidebar.dart` podle
`branding/web/favicon.svg`.

## Struktura repozitáře

| Cesta | Obsah |
|---|---|
| `core/` | jádro v Rustu |
| `ffi/` | C rozhraní pro Flutter |
| `cli/` | příkazová řádka |
| `app/` | Flutter aplikace |
| `docs/` | dokumentace |
| `scripts/` | sestavení, ikona |
| `FEATURES.md` | parita s původní Datovkou |
| `reference/` | zdroják původní Datovky (není v gitu) |

## Vydání

Značka `v*` (třeba `v1.0.1`) na GitHubu spustí `.github/workflows/release.yml`.
Ten k vydání přiloží `DatovkaNG-macos.zip`, `DatovkaNG-linux-amd64.deb`,
`DatovkaNG-linux-arm64.deb`, `DatovkaNG-linux-x86_64.AppImage`,
`DatovkaNG-linux-aarch64.AppImage`, `DatovkaNG-windows-amd64.zip`
a `DatovkaNG-android.apk`, text vydání vezme z `docs/vydani/<značka>.md`.
Aplikace z něj v okně aktualizace ukáže jen část *Co je nového*. Když GitHub
nepřidělí stroj s macOS, stačí job `macos` spustit znovu (Re-run failed
jobs); s Macem jde `DatovkaNG-macos.zip` sestavit i lokálně
(`scripts/build-macos.sh` nad obsahem značky) a vydání založit ručně
(`gh release create … --notes-file docs/vydani/<značka>.md`). APK podepisuje klíč ze secrets
`ANDROID_KEYSTORE_B64` a `ANDROID_KEY_PASSWORD` (originál je mimo repozitář
v `~/.android-release/datovka-ng.jks`, heslo v Klíčence „Datovka NG Android
podpisový klíč“); bez stejného klíče se nová verze nenainstaluje přes starou.
Verze ve značce má odpovídat `version:`
v `app/pubspec.yaml` a `appVersion` v `app/lib/data/updates.dart`. Aplikace
porovná značku nejnovějšího vydání se svou verzí a nabídne aktualizaci.

Každý push do `main` spustí `.github/workflows/build.yml`: testy jádra
a aplikace na Linuxu, Windows i macOS, sestavení balíčků (.deb a AppImage pro
Intel i ARM, zip pro Windows a Mac) a na Windows i Macu krátké spuštění
aplikace se snímkem obrazovky (artefakty `windows-screen`, `macos-screen`).

Vydat jde bez Macu, všechno sestaví GitHub:

1. zvýšit `version:` v `app/pubspec.yaml` a `appVersion`
   v `app/lib/data/updates.dart`,
2. napsat `docs/vydani/v<verze>.md` (vzor je v předchozím vydání),
3. pushnout do `main` a počkat, až `build` projde na všech systémech,
4. `git tag v<verze>` a značku pushnout na GitHub
   (`git push <remote> v<verze>`); `release` pak vydání založí sám.

