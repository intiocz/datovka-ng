import 'dart:io';

import 'package:datovka/data/gov_services.dart';
import 'package:flutter_test/flutter_test.dart';

GovService svc(String id) => govServices.firstWhere((s) => s.id == id);

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadGovTemplates();
  });

  test('all ten services of the original, unique ids', () {
    expect(govServices.map((s) => s.id).toSet(), {
      'SrvcMvCrrVbh',
      'SrvcMvIrVp',
      'SrvcMvRtVt',
      'SrvcMvRtpoVt',
      'SrvcMvSkdVp',
      'SrvcMvVrVp',
      'SrvcMvZrVp',
      'SrvcSzrRobVu',
      'SrvcSzrRobVvu',
      'SrvcSzrRosVv',
    });
    for (final s in govServices) {
      expect(s.boxId, s.id.startsWith('SrvcMv') ? 'xhzkdqv' : '4h8cxph');
      expect(
        s.fileName,
        s.id.startsWith('SrvcMv') ? 'czpathome.xml' : 'zrds.xml',
      );
    }
  });

  test('driver penalty points: attachment XML', () {
    final s = svc('SrvcMvCrrVbh');
    final v = {
      'drivingLicenceId': ' EF 123 456 ',
      'name': ' Jan ',
      'surname': 'Novák',
      'birthDate': '1980-03-07',
    };
    expect(s.validate(v), isNull);
    expect(v['drivingLicenceId'], 'EF123456');
    expect(v['name'], 'Jan');
    expect(
      s.xml(v),
      "<?xml version='1.0' encoding='UTF-8'?>\n"
      '<d:root xmlns:d="http://software602.cz/sample" ancestor_id="" '
      'folder_id="" formdata_id="" fsuser_id="" institute_type="" '
      'ldapPass="" nazev="" page="0" page_id="" query_seq="2" '
      'register="258" retry="0" seq="" templateVersion_id="" '
      'url="" url_release="" user_name="" version="9.7" '
      'xml:lang="cs">\n'
      '  <d:crr>\n'
      '    <d:crrVypisBody>\n'
      '      <d:zadost>\n'
      '        <d:uid/>\n'
      '        <d:autor/>\n'
      '        <d:duvod/>\n'
      '        <d:osobaRC/>\n'
      '        <d:cisloRP_prevod/>\n'
      '        <d:prijmeni>Novák</d:prijmeni>\n'
      '        <d:jmeno>Jan</d:jmeno>\n'
      '        <d:rodnePrijmeni/>\n'
      '        <d:datumNarozeni>1980-03-07</d:datumNarozeni>\n'
      '        <d:datumNarozeni_prevod/>\n'
      '        <d:cisloRP>EF123456</d:cisloRP>\n'
      '        <d:vystup>PDF</d:vystup>\n'
      '      </d:zadost>\n'
      '    </d:crrVypisBody>\n'
      '    <d:x509Certificate KeyName=""/>\n'
      '    <d:vydanyDokument url="">\n'
      '      <d:pdf/>\n'
      '    </d:vydanyDokument>\n'
      '  </d:crr>\n'
      '</d:root>',
    );
    expect(s.envelope(), {
      'recipient_box_id': 'xhzkdqv',
      'annotation': 'CzechPOINT@home - Výpis z Centrálního registru řidičů',
      'sender_ident': 'CzechPOINT@home - 258',
      'publish_own_id': false,
      'allow_subst_delivery': false,
      'personal_delivery': false,
    });
  });

  test('resident register usage: attachment XML and date order', () {
    final s = svc('SrvcSzrRobVvu');
    expect(
      s.validate({'fromDate': '2024-05-01', 'toDate': '2024-04-01'}),
      isNotNull,
    );
    expect(
      s.validate({'fromDate': '2024-02-30', 'toDate': '2024-04-01'}),
      isNotNull,
    );
    final v = {'fromDate': '2024-01-01', 'toDate': '2024-06-30'};
    expect(s.validate(v), isNull);
    expect(
      s.xml(v),
      "<?xml version='1.0' encoding='utf-8'?>\n"
      '<d:FormularData xmlns:d="http://software602.cz/formulare" '
      'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
      'xmlns:date="http://exslt.org/dates-and-times" '
      'xsi:schemaLocation="http://software602.cz/formulare '
      'FormularData_ZRDS11.xsd" version="1.3o">\n'
      '  <d:Identifikace>\n'
      '    <d:Formular>ZRDS5</d:Formular>\n'
      '    <d:Zadatel>\n'
      '      <d:Aifo/>\n'
      '      <d:Idds/>\n'
      '      <d:DatumNarozeni/>\n'
      '      <d:Jmeno/>\n'
      '      <d:MistoNarozeniNazev/>\n'
      '      <d:Prijmeni/>\n'
      '      <d:Doklady>\n'
      '        <d:Cislo/>\n'
      '        <d:Druh/>\n'
      '      </d:Doklady>\n'
      '      <d:AdresaPobytu>\n'
      '        <d:OkresNazev/>\n'
      '        <d:ObecNazev/>\n'
      '        <d:CastObceNazev/>\n'
      '        <d:UliceNazev/>\n'
      '        <d:PostaKod/>\n'
      '        <d:TypCislaDomovnihoKod/>\n'
      '        <d:CisloDomovni/>\n'
      '        <d:CisloOrientacni/>\n'
      '        <d:CisloOrientacniPismeno/>\n'
      '      </d:AdresaPobytu>\n'
      '    </d:Zadatel>\n'
      '  </d:Identifikace>\n'
      '  <d:Parametry>\n'
      '    <d:CasOd>2024-01-01</d:CasOd>\n'
      '    <d:CasDo>2024-06-30</d:CasDo>\n'
      '  </d:Parametry>\n'
      '</d:FormularData>',
    );
    // No sender ident for the registers authority.
    expect(s.envelope().containsKey('sender_ident'), isFalse);
    expect(s.envelope()['recipient_box_id'], '4h8cxph');
  });

  test('criminal record: date split without leading zeros', () {
    final s = svc('SrvcMvRtVt');
    final v = {
      'name': 'Jan',
      'surname': 'Novák',
      'birthDate': '1980-03-07',
      'region': 'Praha',
      'city': 'Praha',
    };
    expect(s.validate(v), isNull);
    final xml = s.xml(v);
    // The original has no newline after the XML declaration here.
    expect(xml, startsWith("<?xml version='1.0' encoding='utf-8'?><d:root "));
    expect(xml, contains('<com:den>7</com:den>'));
    expect(xml, contains('<com:mesic>3</com:mesic>'));
    expect(xml, contains('<com:rok>1980</com:rok>'));
    expect(xml, contains('<com:okres>Praha</com:okres>'));
    expect(xml, isNot(contains('__repl_')));
  });

  test('IČO services fill the number, reject a bad checksum', () {
    for (final id in [
      'SrvcMvIrVp',
      'SrvcMvRtpoVt',
      'SrvcMvSkdVp',
      'SrvcMvVrVp',
      'SrvcMvZrVp',
      'SrvcSzrRosVv',
    ]) {
      final s = svc(id);
      expect(s.validate({'ic': '25596640'}), isNotNull, reason: id);
      final v = {'ic': ' 2559 6641 '};
      expect(s.validate(v), isNull, reason: id);
      final xml = s.xml(v);
      expect(xml, contains('25596641'), reason: id);
      expect(xml, isNot(contains('__repl_')), reason: id);
      expect(xml, isNot(contains('xIC_SUBJECT')), reason: id);
    }
    expect(
      svc('SrvcSzrRosVv').xml({'ic': '25596641'}),
      contains('<d:Ico>25596641</d:Ico>'),
    );
  });

  test('IČO checksum', () {
    expect(isValidIc('25596641'), isTrue);
    expect(isValidIc('00006947'), isTrue);
    expect(isValidIc('6947'), isTrue);
    expect(isValidIc('25596640'), isFalse);
    expect(isValidIc('123456789'), isFalse);
    expect(isValidIc('12a'), isFalse);
    expect(isValidIc(''), isFalse);
  });

  test('owner info from GetOwnerInfoFromLogin2', () {
    final o = GovOwner.fromJson({
      'dbOwnerInfo': {
        'dbID': 'abcdefg',
        'dbType': 'FO',
        'personName': {'pnGivenNames': 'Jan', 'pnLastName': 'Novák'},
        'birthInfo': {
          'biDate': '1980-03-07',
          'biCity': 'Brno',
          'biCounty': 'Brno-město',
        },
      },
    });
    expect(o.boxType, 'FO');
    expect(o.values, {
      'name': 'Jan',
      'surname': 'Novák',
      'birthDate': '1980-03-07',
      'region': 'Brno-město',
      'city': 'Brno',
    });
    expect(svc('SrvcMvRtVt').canSend('PO'), isFalse);
    expect(svc('SrvcMvVrVp').canSend('PO'), isTrue);
    expect(svc('SrvcMvVrVp').canSend('OVM'), isFalse);
  });

  test('attachment is written under the expected file name', () async {
    final s = svc('SrvcSzrRobVu');
    final path = await s.writeAttachment({});
    addTearDown(() => File(path).parent.deleteSync(recursive: true));
    expect(path, endsWith('/zrds.xml'));
    expect(await File(path).readAsString(), s.xml({}));
  });
}
