import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/models.dart';
import 'app_scope.dart';
import 'format.dart';

/// Builds the message envelope (and delivery events) as PDF and opens the
/// system print dialog, which can also save it as PDF.
Future<void> printEnvelope(BuildContext context, Message m) async {
  final s = AppScope.of(context);
  final box = s.boxById(m.boxId);
  final messenger = ScaffoldMessenger.of(context);
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
  try {
    final regular = pw.Font.ttf(
      await rootBundle.load('assets/fonts/PublicSans-Regular.ttf'),
    );
    final bold = pw.Font.ttf(
      await rootBundle.load('assets/fonts/PublicSans-Bold.ttf'),
    );
    final atts = await s.loadAttachments(m);
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

    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: regular, bold: bold),
    );
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(40),
        build: (_) => [
          pw.Text(
            'Obálka datové zprávy',
            style: pw.TextStyle(font: bold, fontSize: 18),
          ),
          pw.SizedBox(height: 4),
          pw.Text(m.subject, style: const pw.TextStyle(fontSize: 13)),
          pw.SizedBox(height: 16),
          row('ID zprávy', m.dmId),
          row('Odesílatel', received ? m.counterparty : ownName),
          row('Adresa odesílatele', received ? m.counterpartyAddress : null),
          row(
            'ID schránky odesílatele',
            received ? m.counterpartyBoxId : ownId,
          ),
          row('Adresát', received ? ownName : m.counterparty),
          row('Adresa adresáta', received ? null : m.counterpartyAddress),
          row('ID schránky adresáta', received ? ownId : m.counterpartyBoxId),
          row(received ? 'Doručeno' : 'Dodáno', longDate(m.delivered)),
          row('Č. j. odesílatele', received ? m.theirRef : m.ourRef),
          row('Č. j. adresáta', received ? m.ourRef : m.theirRef),
          pw.SizedBox(height: 12),
          pw.Text('Přílohy', style: pw.TextStyle(font: bold)),
          for (final a in atts)
            pw.Text('• ${a.name}  (${fileSize(a.sizeBytes)})'),
          if (events.isNotEmpty) ...[
            pw.SizedBox(height: 12),
            pw.Text('Události doručení', style: pw.TextStyle(font: bold)),
            for (final e in events) row('${e['time']}', '${e['description']}'),
          ],
          pw.SizedBox(height: 24),
          pw.Text(
            'Vytištěno z aplikace DATOVKA ${longDate(DateTime.now())}. Právně platným dokladem je '
            'podepsaný originál zprávy (ZFO).',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
          ),
        ],
      ),
    );
    await Printing.layoutPdf(
      name: 'Obalka_${m.dmId}.pdf',
      onLayout: (_) => doc.save(),
    );
  } on Object catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Obálku se nepodařilo vytvořit: $e')),
    );
  }
}
