import 'package:datovka/data/ai.dart';
import 'package:datovka/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a found deadline stays as the message date, a meeting does not', () {
    final withSuggestion = AiResult.fromJson({
      'summary': 's',
      'suggested_deadline': '2026-10-20',
      'events': [
        {
          'title': 'Lhůta',
          'date': '2026-10-16',
          'kind': 'lhuta',
        },
      ],
    });
    expect(rememberedDeadline(withSuggestion), DateTime.parse('2026-10-20'));

    final onlyPayment = AiResult.fromJson({
      'summary': 's',
      'events': [
        {'title': 'Jednání', 'date': '2026-11-03', 'kind': 'jednani'},
        {'title': 'Úhrada', 'date': '2026-10-16', 'kind': 'platba'},
      ],
    });
    expect(rememberedDeadline(onlyPayment), DateTime.parse('2026-10-16'));

    final meeting = AiResult.fromJson({
      'summary': 's',
      'events': [
        {'title': 'Jednání', 'date': '2026-11-03', 'kind': 'jednani'},
      ],
    });
    expect(rememberedDeadline(meeting), isNull);
  });

  test('builds an iCalendar file with all-day and timed events', () {
    final m = Message(
      boxId: 'abc',
      dmId: '123',
      direction: Direction.received,
      subject: 'Výzva; k úhradě',
      counterparty: 'Finanční úřad',
      counterpartyAddress: '',
      delivered: DateTime(2026, 10, 1),
    );
    final r = AiResult.fromJson({
      'summary': 's',
      'suggested_deadline': '2026-10-16',
      'events': [
        {
          'title': 'Zaplatit daň',
          'date': '2026-10-16',
          'time': '',
          'end_time': '',
          'kind': 'platba',
          'location': '',
          'description': 'Úhrada, včetně příslušenství',
          'source': 'do 15 dnů',
        },
        {
          'title': 'Jednání',
          'date': '2026-11-03',
          'time': '09:30',
          'end_time': '',
          'kind': 'jednani',
          'location': 'Brno',
          'description': '',
          'source': '',
        },
        {
          'title': 'bez data',
          'date': 'nevim',
          'time': '',
          'end_time': '',
          'kind': 'jine',
          'location': '',
          'description': '',
          'source': '',
        },
      ],
    });
    expect(r.events, hasLength(2));
    expect(r.suggestedDeadline, DateTime(2026, 10, 16));
    final ics = buildIcs(m, r.events);
    // The payment is due on the 16th; the calendar gets it a day early.
    expect(ics, contains('DTSTART;VALUE=DATE:20261015'));
    expect(ics, contains('DTEND;VALUE=DATE:20261016'));
    expect(ics, contains('Skutečná lhůta je 16. 10. 2026'));
    // A meeting keeps its date.
    expect(ics, contains('DTSTART:20261103T093000'));
    expect(ics, contains('DTEND:20261103T103000'));
    expect(ics, contains('TRIGGER:-P1D'));
    expect(ics, contains(r'Úhrada\, včetně'));
    expect(ics, contains(r'Výzva\; k úhradě'));
    expect(ics.split('\r\n').where((l) => l == 'BEGIN:VEVENT'), hasLength(2));
  });

  test('the phone calendar gets deadlines a day early with a reminder', () {
    final m = Message(
      boxId: 'abc',
      dmId: '123',
      direction: Direction.received,
      subject: 'Výzva',
      counterparty: 'Finanční úřad',
      counterpartyAddress: '',
      delivered: DateTime(2026, 10, 1),
    );
    final r = AiResult.fromJson({
      'summary': 's',
      'events': [
        {'title': 'Úhrada', 'date': '2026-10-16', 'kind': 'platba'},
        {
          'title': 'Jednání',
          'date': '2026-11-03',
          'time': '09:30',
          'kind': 'jednani',
          'location': 'Brno',
        },
      ],
    });
    final [pay, meeting] = calendarEntries(m, r.events);
    expect(pay['allDay'], true);
    expect(pay['alarm'], true);
    expect(pay['start'], DateTime(2026, 10, 15).millisecondsSinceEpoch);
    expect(pay['end'], DateTime(2026, 10, 16).millisecondsSinceEpoch);
    expect(pay['notes'] as String, contains('Skutečná lhůta je 16. 10. 2026'));
    expect(meeting['allDay'], false);
    expect(meeting['alarm'], false);
    expect(meeting['start'], DateTime(2026, 11, 3, 9, 30).millisecondsSinceEpoch);
    expect(meeting['end'], DateTime(2026, 11, 3, 10, 30).millisecondsSinceEpoch);
    expect(meeting['location'], 'Brno');
  });
}
