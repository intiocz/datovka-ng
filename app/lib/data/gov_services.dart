// E-Government services: pre-filled requests sent as a data message to the
// automated data boxes of the Ministry of the Interior (CzechPOINT@home) and
// of the Basic Registers Authority. Port of the original Datovka
// `src/datovka_shared/gov_services/service/gov_*.cpp`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'user_error.dart';

/// Recipient of the CzechPOINT@home requests (`gov_service.h`, GOV_MV_*).
const govMvBoxId = 'xhzkdqv';
const govMvName = 'Automat CzP (Ministerstvo vnitra)';
const govMvFileName = 'czpathome.xml';

/// Recipient of the basic registers requests (`gov_service.h`, GOV_SZR_*).
const govSzrBoxId = '4h8cxph';
const govSzrName = 'Automat ZR (Správa základních registrů)';
const govSzrFileName = 'zrds.xml';

/// How a field value is checked and normalised before sending.
enum GovCheck {
  /// All white space removed, must not be empty.
  noSpaces,

  /// Trimmed, must not be empty.
  trimmed,

  /// A date in `yyyy-MM-dd`.
  date,

  /// Company identification number (IČO) with a valid checksum.
  ic,
}

/// One form field of a service.
class GovField {
  final String key;
  final String label;
  final String placeholder;

  /// Filled in by the user; otherwise taken from the box owner information.
  final bool userInput;
  final GovCheck check;

  const GovField(
    this.key,
    this.label, {
    this.placeholder = '',
    this.userInput = false,
    required this.check,
  });

  bool get isDate => check == GovCheck.date;
}

/// Box types allowed for services meant for natural persons only.
const _personTypes = {'OVM_FO', 'FO'};

/// Box types allowed for the remaining services.
const _allTypes = {
  'OVM_FO', 'OVM_PFO', 'OVM_PO', 'PO', 'PO_ZAK', 'PO_REQ', 'PFO', //
  'PFO_ADVOK', 'PFO_DANPOR', 'PFO_INSSPR', 'PFO_AUDITOR', 'PFO_ZNALEC',
  'PFO_TLUMOCNIK', 'PFO_ARCH', 'PFO_AIAT', 'PFO_AZI', 'PFO_REQ', 'FO',
};

const _icField = GovField(
  'ic',
  'Identifikační číslo (IČO)',
  placeholder: 'Zadejte identifikační číslo (IČO)',
  userInput: true,
  check: GovCheck.ic,
);

/// A request form and how it is turned into a data message.
class GovService {
  /// Internal identifier of the original (`internalId()`).
  final String id;
  final String name;
  final String boxId;
  final String institute;

  /// Message subject (`dmAnnotation`).
  final String annotation;

  /// Sender's file mark (`dmSenderIdent`); none for the registers authority.
  final String? senderIdent;

  /// Attachment file name (`dmFileDescr`).
  final String fileName;
  final List<GovField> fields;

  /// ISDS box types (`dbType`) that may send this request.
  final Set<String> boxTypes;

  /// Placeholder to value, for already validated values.
  final Map<String, String> Function(Map<String, String> v) replacements;

  const GovService._({
    required this.id,
    required this.name,
    required this.boxId,
    required this.institute,
    required this.annotation,
    required this.senderIdent,
    required this.fileName,
    required this.fields,
    required this.boxTypes,
    required this.replacements,
  });

  bool canSend(String? boxType) =>
      boxType == null || boxTypes.contains(boxType);

  /// Fields taken from the box owner information.
  bool get needsOwnerInfo => fields.any((f) => !f.userInput);

  /// Checks [values] and normalises them in place, as the original does
  /// before sending. Returns an error message, or null when all is valid.
  String? validate(Map<String, String> values) {
    for (final f in fields) {
      final raw = values[f.key] ?? '';
      switch (f.check) {
        case GovCheck.noSpaces:
          final v = withoutSpaces(raw);
          values[f.key] = v;
          if (v.isEmpty) return 'Pole „${f.label}“ je prázdné.';
        case GovCheck.trimmed:
          final v = raw.trim();
          values[f.key] = v;
          if (v.isEmpty) return 'Pole „${f.label}“ je prázdné.';
        case GovCheck.date:
          final v = withoutSpaces(raw);
          values[f.key] = v;
          if (parseGovDate(v) == null) {
            return 'Pole „${f.label}“ obsahuje neplatné datum „$v“.';
          }
        case GovCheck.ic:
          final v = withoutSpaces(raw);
          values[f.key] = v;
          if (!isValidIc(v)) {
            return 'Pole „${f.label}“ obsahuje neplatnou hodnotu „$v“.';
          }
      }
    }
    if (id == 'SrvcSzrRobVvu' &&
        parseGovDate(values['fromDate']!)!
            .isAfter(parseGovDate(values['toDate']!)!)) {
      return 'Datum začátku nemůže být pozdější než datum konce.';
    }
    return null;
  }

  /// The attachment content for already validated [values].
  String xml(Map<String, String> values) {
    final outTemplate = govTemplates[id];
    if (outTemplate == null) {
      throw UserError('Šablona $id není načtená.');
    }
    var out = outTemplate;
    replacements(values).forEach((k, v) {
      out = out.replaceAll(k, _escape(v));
    });
    return out;
  }

  /// Envelope fields of `OutgoingMessage` (`Gov::Service::dataMessage`).
  Map<String, Object?> envelope() => {
    'recipient_box_id': boxId,
    'annotation': annotation,
    'sender_ident': ?senderIdent,
    'publish_own_id': false,
    'allow_subst_delivery': false,
    'personal_delivery': false,
  };

  /// Writes the attachment into a fresh temporary folder (the file name is
  /// what the recipient's automaton expects) and returns its path.
  Future<String> writeAttachment(Map<String, String> values) async {
    final dir = await Directory.systemTemp.createTemp('datovka-gov-');
    final f = File('${dir.path}/$fileName');
    await f.writeAsString(xml(values));
    return f.path;
  }
}

/// Values in the templates are plain text; the original inserts them
/// unescaped, which only differs for `&`, `<` and `>` (invalid XML anyway).
String _escape(String v) =>
    v.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String withoutSpaces(String s) => s.replaceAll(RegExp(r'\s+'), '');

/// Parses `yyyy-MM-dd`; null when the text is not a valid date.
DateTime? parseGovDate(String s) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s);
  if (m == null) return null;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  final dt = DateTime.utc(y, mo, d);
  if (dt.year != y || dt.month != mo || dt.day != d) return null;
  return dt;
}

String formatGovDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// IČO: at most 8 digits, the last one is a mod-11 checksum
/// (`gov_services/helper.cpp`).
bool isValidIc(String s) {
  if (!RegExp(r'^\d{1,8}$').hasMatch(s)) return false;
  final n = int.parse(s);
  final d = [for (var i = 7; i >= 0; i--) (n ~/ _pow10[i]) % 10];
  // d[0] is the highest (8th) digit, d[7] the checksum.
  var sum = 0;
  for (var i = 0; i < 7; i++) {
    sum += (8 - i) * d[i];
  }
  return d[7] == (11 - sum % 11) % 10;
}

const _pow10 = [1, 10, 100, 1000, 10000, 100000, 1000000, 10000000];

/// XML bodies of the services, loaded from `assets/gov/templates.json`.
final Map<String, String> govTemplates = {};

Future<void> loadGovTemplates() async {
  final raw = await rootBundle.loadString('assets/gov/templates.json');
  final map = jsonDecode(raw) as Map<String, dynamic>;
  govTemplates
    ..clear()
    ..addAll(map.map((k, v) => MapEntry(k, v as String)));
}

Map<String, String> _ic(String placeholder, Map<String, String> v) => {
  placeholder: v['ic']!,
};

/// All services in the order of the original (`gov_services_all.cpp`).
final List<GovService> govServices = [
  GovService._(
    id: 'SrvcMvCrrVbh',
    name: 'Výpis bodového hodnocení z Centrálního registru řidičů',
    boxId: govMvBoxId,
    institute: govMvName,
    annotation: 'CzechPOINT@home - Výpis z Centrálního registru řidičů',
    senderIdent: 'CzechPOINT@home - 258',
    fileName: govMvFileName,
    boxTypes: _personTypes,
    fields: const [
      GovField(
        'drivingLicenceId',
        'Číslo řidičského průkazu',
        placeholder: 'Zadejte číslo řidičského průkazu bez mezer',
        userInput: true,
        check: GovCheck.noSpaces,
      ),
      GovField('name', 'Jméno držitele schránky', check: GovCheck.trimmed),
      GovField(
        'surname',
        'Příjmení držitele schránky',
        check: GovCheck.trimmed,
      ),
      GovField('birthDate', 'Datum narození', check: GovCheck.date),
    ],
    replacements: (v) => {
      '__repl_DRIVE_LICENSE_ID__': v['drivingLicenceId']!,
      '__repl_NAME__': v['name']!,
      '__repl_SURNAME__': v['surname']!,
      '__repl_BIRTH_DATE__': v['birthDate']!,
    },
  ),
  GovService._(
    id: 'SrvcMvIrVp',
    name: 'Výpis z insolvenčního rejstříku',
    boxId: govMvBoxId,
    institute: govMvName,
    annotation: 'CzechPOINT@home - Výpis z insolvenčního rejstříku',
    senderIdent: 'CzechPOINT@home - 261',
    fileName: govMvFileName,
    boxTypes: _allTypes,
    fields: const [_icField],
    replacements: (v) => _ic('__repl_IC_SUBJECT__', v),
  ),
  GovService._(
    id: 'SrvcMvRtVt',
    name: 'Výpis z Rejstříku trestů',
    boxId: govMvBoxId,
    institute: govMvName,
    annotation: 'CzechPOINT@home - Žádost o výpis z Rejstříku trestů',
    senderIdent: 'CzechPOINT@home - 262',
    fileName: govMvFileName,
    boxTypes: _personTypes,
    fields: const [
      GovField('name', 'Jméno držitele schránky', check: GovCheck.trimmed),
      GovField(
        'surname',
        'Příjmení držitele schránky',
        check: GovCheck.trimmed,
      ),
      GovField('birthDate', 'Datum narození', check: GovCheck.date),
      GovField('region', 'Okres narození', check: GovCheck.trimmed),
      GovField('city', 'Obec narození', check: GovCheck.trimmed),
    ],
    replacements: (v) {
      final d = parseGovDate(v['birthDate']!)!;
      // Qt formats "d", "M" and "yyyy": day and month without leading zeros.
      return {
        '__repl_NAME__': v['name']!,
        '__repl_SURNAME__': v['surname']!,
        '__repl_BIRTH_DATE_DAY__': '${d.day}',
        '__repl_BIRTH_DATE_MONTH__': '${d.month}',
        '__repl_BIRTH_DATE_YEAR__': d.year.toString().padLeft(4, '0'),
        '__repl_REGION__': v['region']!,
        '__repl_CITY__': v['city']!,
      };
    },
  ),
  GovService._(
    id: 'SrvcMvRtpoVt',
    name: 'Výpis z Rejstříku trestů právnických osob',
    boxId: govMvBoxId,
    institute: govMvName,
    annotation: 'CzechPOINT@home - Výpis z Rejstříku trestů právnických osob',
    senderIdent: 'CzechPOINT@home - 269',
    fileName: govMvFileName,
    boxTypes: _allTypes,
    fields: const [_icField],
    replacements: (v) => _ic('__repl_SUBJECT_IC__', v),
  ),
  GovService._(
    id: 'SrvcMvSkdVp',
    name: 'Výpis ze seznamu kvalifikovaných dodavatelů',
    boxId: govMvBoxId,
    institute: govMvName,
    annotation: 'CzechPOINT@home - Výpis ze seznamu kvalifikovaných dodavatelů',
    senderIdent: 'CzechPOINT@home - 259',
    fileName: govMvFileName,
    boxTypes: _allTypes,
    fields: const [_icField],
    replacements: (v) => _ic('__repl_IC_SUBJECT__', v),
  ),
  GovService._(
    id: 'SrvcMvVrVp',
    name: 'Výpis z veřejného rejstříku',
    boxId: govMvBoxId,
    institute: govMvName,
    annotation: 'CzechPOINT@home - Výpis z Veřejného rejstříku',
    senderIdent: 'CzechPOINT@home - 251',
    fileName: govMvFileName,
    boxTypes: _allTypes,
    fields: const [_icField],
    replacements: (v) => _ic('xIC_SUBJECT', v),
  ),
  GovService._(
    id: 'SrvcMvZrVp',
    name: 'Výpis z živnostenského rejstříku',
    boxId: govMvBoxId,
    institute: govMvName,
    annotation: 'CzechPOINT@home - Výpis z živnostenského rejstříku',
    senderIdent: 'CzechPOINT@home - 252',
    fileName: govMvFileName,
    boxTypes: _allTypes,
    fields: const [_icField],
    replacements: (v) => _ic('__repl_IC_SUBJECT__', v),
  ),
  GovService._(
    id: 'SrvcSzrRobVu',
    name: 'Výpis z Registru obyvatel',
    boxId: govSzrBoxId,
    institute: govSzrName,
    annotation: 'Výpis z Registru obyvatel',
    senderIdent: null,
    fileName: govSzrFileName,
    boxTypes: _personTypes,
    fields: const [],
    replacements: (_) => const {},
  ),
  GovService._(
    id: 'SrvcSzrRobVvu',
    name: 'Výpis o využití údajů z registru obyvatel',
    boxId: govSzrBoxId,
    institute: govSzrName,
    annotation: 'Výpis o využití údajů z registru obyvatel',
    senderIdent: null,
    fileName: govSzrFileName,
    boxTypes: _personTypes,
    fields: const [
      GovField(
        'fromDate',
        'Od',
        placeholder: 'Vyberte počáteční datum',
        userInput: true,
        check: GovCheck.date,
      ),
      GovField(
        'toDate',
        'Do',
        placeholder: 'Vyberte koncové datum',
        userInput: true,
        check: GovCheck.date,
      ),
    ],
    replacements: (v) => {
      '__repl_FROM_DATE__': v['fromDate']!,
      '__repl_TO_DATE__': v['toDate']!,
    },
  ),
  GovService._(
    id: 'SrvcSzrRosVv',
    name: 'Veřejný výpis z registru osob',
    boxId: govSzrBoxId,
    institute: govSzrName,
    annotation: 'Veřejný výpis z registru osob',
    senderIdent: null,
    fileName: govSzrFileName,
    boxTypes: _allTypes,
    fields: const [_icField],
    replacements: (v) => _ic('__repl_ICO_ICO__', v),
  ),
];

/// Owner data used by the forms, from the `owner_info` operation
/// (GetOwnerInfoFromLogin2, any nesting).
class GovOwner {
  final String? boxType;
  final Map<String, String> values;

  const GovOwner(this.boxType, this.values);

  factory GovOwner.fromJson(Object? json) {
    String? find(Object? n, String key) {
      if (n is Map) {
        final v = n[key];
        if (v is String && v.isNotEmpty) return v;
        for (final c in n.values) {
          final r = find(c, key);
          if (r != null) return r;
        }
      } else if (n is List) {
        for (final c in n) {
          final r = find(c, key);
          if (r != null) return r;
        }
      }
      return null;
    }

    final birth = find(json, 'biDate');
    return GovOwner(find(json, 'dbType'), {
      'name': ?(find(json, 'pnGivenNames') ?? find(json, 'pnFirstName')),
      'surname': ?find(json, 'pnLastName'),
      if (birth != null && birth.length >= 10)
        'birthDate': birth.substring(0, 10),
      'region': ?find(json, 'biCounty'),
      'city': ?find(json, 'biCity'),
    });
  }
}
