import 'package:flutter/material.dart';

import '../theme.dart';
import 'info_view.dart';

/// Overall result of a local verification report from the core.
bool signatureOk(Map<String, dynamic> r) {
  if (r['signature_valid'] != true || r['chain_trusted'] == false) return false;
  final ts = r['timestamp'] as Map?;
  if (ts != null &&
      (ts['signature_valid'] != true || ts['imprint_matches'] == false)) {
    return false;
  }
  final h = r['dm_hash'] as Map?;
  return h?['matches_content'] != false;
}

String? _name(dynamic n) => n is Map
    ? (n['common_name'] ?? n['organization'] ?? n['dn']) as String?
    : null;

String _yes(dynamic v) => switch (v) {
  true => 'ano',
  false => 'NE',
  _ => 'neověřeno',
};

/// Details of the signature and time stamps of a stored original.
Future<void> showSignatureReport(BuildContext context, Map<String, dynamic> r) {
  final t = Tokens.of(context);
  final text = Theme.of(context).textTheme;
  final ts = r['timestamp'] as Map?;
  final sts = r['signature_timestamp'] as Map?;
  final problems = (r['problems'] as List? ?? const []).cast<String>();
  return showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Podpis a časové razítko'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                signatureOk(r)
                    ? 'Originál je pravý a nezměněný.'
                    : 'Ověření neprošlo.',
                style: text.titleMedium?.copyWith(
                  color: signatureOk(r) ? t.ok : t.danger,
                ),
              ),
              for (final p in problems)
                Text('• $p', style: text.bodySmall?.copyWith(color: t.danger)),
              const SizedBox(height: 12),
              InfoView(
                data: {
                  'Podpis platný': _yes(r['signature_valid']),
                  'Podepsal': _name(r['signer']),
                  'Vydavatel certifikátu': _name(r['issuer']),
                  'Certifikát platí':
                      '${r['cert_not_before'] ?? '?'} – ${r['cert_not_after'] ?? '?'}',
                  'Důvěryhodný řetězec': _yes(r['chain_trusted']),
                  'Certifikační cesta': (r['chain'] as List? ?? const []).join(
                    ' → ',
                  ),
                  'Algoritmus':
                      '${r['digest_algorithm'] ?? ''} ${r['signature_algorithm'] ?? ''}'
                          .trim(),
                  'Otisk zprávy odpovídá obsahu': _yes(
                    (r['dm_hash'] as Map?)?['matches_content'],
                  ),
                  if (ts != null) ...{
                    'Časové razítko vydáno': ts['gen_time'],
                    'Razítko platné': _yes(ts['signature_valid']),
                    'Razítko patří ke zprávě': _yes(ts['imprint_matches']),
                    'Vydavatel razítka': _name(ts['tsa']),
                    'Certifikát razítka platí do': ts['tsa_cert_not_after'],
                  },
                  if (sts != null)
                    'Razítko podpisu':
                        '${sts['gen_time']} (${_yes(sts['signature_valid'])})',
                },
              ),
              const SizedBox(height: 8),
              Text(
                'Ověřeno v aplikaci bez připojení; kontrola odvolání certifikátů (CRL/OCSP) se neprovádí.',
                style: text.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Zavřít'),
        ),
      ],
    ),
  );
}
