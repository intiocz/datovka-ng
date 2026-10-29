import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/app_state.dart';
import '../data/models.dart';
import 'app_scope.dart';
import 'format.dart';

/// What the PDF of a message shows.
enum MessagePdf {
  /// Envelope, attachments and delivery events.
  envelope('Obálka datové zprávy', 'Obalka'),

  /// Delivery receipt: who, when, and the events of delivery.
  delivery('Doručenka datové zprávy', 'Dorucenka');

  final String title;
  final String fileStem;

  const MessagePdf(this.title, this.fileStem);
}

/// Builds the envelope (and delivery events) as PDF and opens the system
/// print dialog, which can also save it as PDF.
Future<void> printEnvelope(BuildContext context, Message m) async {
  final s = AppScope.of(context);
  final messenger = ScaffoldMessenger.of(context);
  try {
    final bytes = await buildMessagePdf(s, m, MessagePdf.envelope);
    await Printing.layoutPdf(
      name: 'Obalka_${m.dmId}.pdf',
      onLayout: (_) => bytes,
    );
  } on Object catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Obálku se nepodařilo vytvořit: $e')),
    );
  }
}

/// Saves the envelope or the delivery receipt as a PDF file. On a phone the
/// file opens in the preview, where it can be shared or saved.
Future<void> saveMessagePdf(
  BuildContext context,
  Message m,
  MessagePdf kind,
) async {
  final s = AppScope.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final name = '${kind.fileStem}_${m.dmId}.pdf';
  try {
    final bytes = await buildMessagePdf(s, m, kind);
    if (Platform.isIOS || Platform.isAndroid) {
      final path = s.tempPath(name);
      if (path == null) return;
      await File(path).writeAsBytes(bytes);
      await s.core?.openFile(path);
      return;
    }
    final loc = await getSaveLocation(suggestedName: name);
    if (loc == null) return;
    await File(loc.path).writeAsBytes(bytes);
    messenger.showSnackBar(SnackBar(content: Text('Uloženo: ${loc.path}')));
  } on Object catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('PDF se nepodařilo vytvořit: $e')),
    );
  }
}

Future<Uint8List> buildMessagePdf(
  AppState s,
  Message m,
  MessagePdf kind,
) async {
  final box = s.boxById(m.boxId);
  List events = const [];
  if (box != null) {
    try {
      events =
          (s.localOp(box, 'delivery_events', {'dm_id': m.dmId}) as List?) ??
          const [];
    } on Object {
      events = const [];
    }
  }
  final regular = pw.Font.ttf(
    await rootBundle.load('assets/fonts/PublicSans-Regular.ttf'),
  );
  final bold = pw.Font.ttf(
    await rootBundle.load('assets/fonts/PublicSans-Bold.ttf'),
  );
  final envelope = kind == MessagePdf.envelope;
  final atts = envelope ? await s.loadAttachments(m) : const <Attachment>[];
  final received = m.direction == Direction.received;
  final ownName = box?.name ?? m.boxId;
  final ownId = box?.isdsId ?? m.boxId;

  pw.Widget row(String k, String? v) => v == null || v.isEmpty
      ? pw.SizedBox()
      : pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 2),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.SizedBox(
                width: 140,
                child: pw.Text(
                  k,
                  style: const pw.TextStyle(color: PdfColors.grey700),
                ),
              ),
              pw.Expanded(child: pw.Text(v)),
            ],
          ),
        );

  String when(Object? raw) {
    final t = DateTime.tryParse('$raw'.replaceFirst(' ', 'T'));
    return t == null ? '$raw' : longDate(t.toLocal());
  }

  final doc = pw.Document(
    theme: pw.ThemeData.withFont(base: regular, bold: bold),
  );
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(40),
      build: (_) => [
        pw.Text(kind.title, style: pw.TextStyle(font: bold, fontSize: 18)),
        pw.SizedBox(height: 4),
        pw.Text(m.subject, style: const pw.TextStyle(fontSize: 13)),
        pw.SizedBox(height: 16),
        row('ID zprávy', m.dmId),
        row('Odesílatel', received ? m.counterparty : ownName),
        row('Adresa odesílatele', received ? m.counterpartyAddress : null),
        row('ID schránky odesílatele', received ? m.counterpartyBoxId : ownId),
        row('Adresát', received ? ownName : m.counterparty),
        row('Adresa adresáta', received ? null : m.counterpartyAddress),
        row('ID schránky adresáta', received ? ownId : m.counterpartyBoxId),
        row(received ? 'Doručeno' : 'Dodáno', longDate(m.delivered)),
        row('Č. j. odesílatele', received ? m.theirRef : m.ourRef),
        row('Č. j. adresáta', received ? m.ourRef : m.theirRef),
        if (envelope) ...[
          pw.SizedBox(height: 12),
          pw.Text('Přílohy', style: pw.TextStyle(font: bold)),
          for (final a in atts)
            pw.Text('• ${a.name}  (${fileSize(a.sizeBytes)})'),
        ],
        pw.SizedBox(height: 12),
        pw.Text('Události doručení', style: pw.TextStyle(font: bold)),
        if (events.isEmpty)
          pw.Text(
            'Doručenka zatím není stažená.',
            style: const pw.TextStyle(color: PdfColors.grey700),
          )
        else
          for (final e in events) row(when(e['time']), '${e['description']}'),
        pw.SizedBox(height: 24),
        pw.Text(
          'Vytvořeno v aplikaci Datovka NG ${longDate(DateTime.now())}. Právně '
          'platným dokladem je podepsaný originál ${envelope ? 'zprávy' : 'doručenky'} (ZFO).',
          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
        ),
      ],
    ),
  );
  return doc.save();
}
