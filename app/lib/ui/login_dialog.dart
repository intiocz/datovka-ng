import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../data/app_state.dart';
import '../data/models.dart';
import '../theme.dart';
import 'app_scope.dart';

/// Login for one box. Opened only from an explicit user action, never by sync.
Future<void> showLoginDialog(BuildContext context, DataBox box) => showDialog(
  context: context,
  builder: (_) => AppScope(
    state: AppScope.of(context),
    child: _LoginDialog(box: box),
  ),
);

enum _Step { credentials, secondFactor, waitingForApp }

class _LoginDialog extends StatefulWidget {
  final DataBox box;

  const _LoginDialog({required this.box});

  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
  final _password = TextEditingController();
  final _code = TextEditingController();
  var _step = _Step.credentials;
  var _busy = false;
  String? _error;
  var _waiting = false;
  String? _p12;

  LoginMethod get method => widget.box.login;
  bool get _sms => method == LoginMethod.passwordSms;

  AppState? _state;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _state = AppScope.of(context);
  }

  @override
  void dispose() {
    // Closing the dialog cancels a pending mobile key login.
    if (_waiting) _state?.cancelLogin(widget.box);
    _waiting = false;
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _continue() => _run(() async {
    final s = AppScope.of(context);
    switch (method) {
      case LoginMethod.mobileKey:
        await s.mobileKeyStart(widget.box);
        if (!mounted) return;
        setState(() => _step = _Step.waitingForApp);
        await _waitForPhone();
      case LoginMethod.passwordSms || LoginMethod.passwordOtp:
        if (_step == _Step.credentials && _sms) {
          // Ask ISDS to send the SMS code.
          final done = await s.loginWithCode(
            widget.box,
            password: _password.text,
            sms: true,
          );
          if (done) return _close();
          if (mounted) setState(() => _step = _Step.secondFactor);
        } else if (_step == _Step.credentials) {
          setState(() => _step = _Step.secondFactor);
        } else {
          final done = await s.loginWithCode(
            widget.box,
            password: _password.text,
            code: _code.text.trim(),
            sms: _sms,
          );
          if (done) _close();
        }
      case LoginMethod.certificate:
        await s.loginCertificate(
          widget.box,
          _password.text,
          p12Path: _p12 ?? '',
        );
        _close();
      case LoginMethod.password:
        await s.loginPassword(widget.box, _password.text);
        _close();
    }
  });

  /// Polls ISDS while the dialog is open; closing the dialog stops it.
  Future<void> _waitForPhone() async {
    final s = AppScope.of(context);
    _waiting = true;
    while (_waiting && mounted) {
      final done = await s.mobileKeyPoll(widget.box);
      if (done) {
        _waiting = false;
        return _close();
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  void _close() {
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final stored = widget.box.storedCredentials;

    final body = switch (_step) {
      _Step.credentials => [
        if (method == LoginMethod.mobileKey)
          Text(
            stored
                ? 'Po kliknutí na Pokračovat přijde do telefonu žádost o přihlášení. '
                      'Potvrďte ji v aplikaci Mobilní klíč.'
                : 'Schránka nemá uložený komunikační kód mobilního klíče.',
            style: text.bodyMedium,
          )
        else ...[
          if (method == LoginMethod.certificate)
            Row(
              children: [
                Expanded(
                  child: Text(
                    _p12 ?? 'Certifikát podle nastavení schránky',
                    style: text.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final f = await openFile(
                      acceptedTypeGroups: const [
                        XTypeGroup(
                          label: 'Certifikát',
                          extensions: ['p12', 'pfx'],
                        ),
                      ],
                    );
                    if (f != null) setState(() => _p12 = f.path);
                  },
                  child: const Text('Vybrat soubor…'),
                ),
              ],
            ),
          TextField(
            controller: _password,
            obscureText: true,
            autofocus: true,
            decoration: InputDecoration(
              labelText: method == LoginMethod.certificate
                  ? 'Heslo k certifikátu'
                  : 'Heslo',
              helperText: stored && method != LoginMethod.certificate
                  ? 'Heslo je uložené, pole můžete nechat prázdné.'
                  : method == LoginMethod.password
                  ? 'Uloží se do úložiště hesel tohoto zařízení, ne do archivu.'
                  : null,
              helperMaxLines: 2,
            ),
            onSubmitted: (_) => _continue(),
          ),
        ],
      ],
      _Step.secondFactor => [
        Text(
          _sms
              ? 'Na váš telefon přišel SMS kód.'
              : 'Zadejte kód z ověřovací aplikace nebo tokenu.',
          style: text.bodyMedium,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _code,
          autofocus: true,
          keyboardType: TextInputType.number,
          style: text.titleMedium?.copyWith(
            fontFeatures: tabular,
            letterSpacing: 4,
          ),
          decoration: const InputDecoration(labelText: 'Kód'),
          onSubmitted: (_) => _continue(),
        ),
        if (_sms)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      await AppScope.of(context).loginWithCode(
                        widget.box,
                        password: _password.text,
                        sms: true,
                      );
                    }),
              child: const Text('Poslat nový kód'),
            ),
          ),
      ],
      _Step.waitingForApp => [
        Row(
          children: [
            SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                'Čekám na potvrzení v aplikaci Mobilní klíč. Když okno zavřete, '
                'přihlášení se zruší a nic dalšího se nestane.',
                style: text.bodyMedium,
              ),
            ),
          ],
        ),
      ],
    };

    return AlertDialog(
      title: const Text('Přihlásit ke schránce'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.box.name, style: text.titleMedium),
            Text(
              '${method.label}, uživatel ${widget.box.username}',
              style: text.bodySmall,
            ),
            const SizedBox(height: 18),
            ...body,
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: text.bodySmall?.copyWith(color: t.danger)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Zavřít'),
        ),
        if (_step != _Step.waitingForApp)
          FilledButton(
            onPressed: _busy ? null : _continue,
            child: _busy
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    _step == _Step.credentials && method != LoginMethod.password
                        ? 'Pokračovat'
                        : 'Přihlásit',
                  ),
          ),
      ],
    );
  }
}

/// Adding a new data box account.
Future<void> showAddBoxDialog(BuildContext context) => showDialog(
  context: context,
  builder: (_) =>
      AppScope(state: AppScope.of(context), child: const _AddBoxDialog()),
);

class _AddBoxDialog extends StatefulWidget {
  const _AddBoxDialog();

  @override
  State<_AddBoxDialog> createState() => _AddBoxDialogState();
}

class _AddBoxDialogState extends State<_AddBoxDialog> {
  final _name = TextEditingController();
  final _user = TextEditingController();
  final _secret = TextEditingController();
  String? _error;
  var _method = LoginMethod.password;
  var _test = false;

  @override
  void dispose() {
    _name.dispose();
    _user.dispose();
    _secret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('Přidat schránku'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Pojmenování',
                  hintText: 'Např. Firma, Osobní',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _user,
                decoration: const InputDecoration(
                  labelText: 'Uživatelské jméno',
                ),
              ),
              const SizedBox(height: 18),
              Text('Způsob přihlášení', style: text.titleMedium),
              const SizedBox(height: 6),
              LoginMethodFields(
                method: _method,
                secret: _secret,
                onChanged: (m) => setState(() => _method = m),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(color: Tokens.of(context).danger),
                  ),
                ),
              SwitchListTile(
                value: _test,
                onChanged: (v) => setState(() => _test = v),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text('Testovací prostředí ISDS', style: text.bodyMedium),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: () {
            final user = _user.text.trim();
            if (user.isEmpty) return;
            try {
              AppScope.of(context).addBox(
                DataBox(
                  id: user,
                  name: _name.text.trim().isEmpty ? user : _name.text.trim(),
                  kind: 'Nová schránka',
                  username: user,
                  login: _method,
                  session: Session.expired,
                  testEnv: _test,
                ),
                secret: _secret.text,
              );
              Navigator.of(context).pop();
            } on Object catch (e) {
              setState(() => _error = '$e');
            }
          },
          child: const Text('Přidat schránku'),
        ),
      ],
    );
  }
}

/// Choice of the login method with the field for the password or the mobile
/// key code. Shared by adding a box and by changing how it logs in.
class LoginMethodFields extends StatelessWidget {
  final LoginMethod method;
  final TextEditingController secret;
  final ValueChanged<LoginMethod> onChanged;
  final String? passwordHelper;

  const LoginMethodFields({
    super.key,
    required this.method,
    required this.secret,
    required this.onChanged,
    this.passwordHelper,
  });

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RadioGroup<LoginMethod>(
          groupValue: method,
          onChanged: (v) => onChanged(v!),
          child: Column(
            children: [
              for (final m in LoginMethod.values)
                RadioListTile<LoginMethod>(
                  value: m,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    m.label,
                    style: text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(m.description, style: text.bodySmall),
                ),
            ],
          ),
        ),
        if (method.interactive)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: t.accentSoft,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'Tento způsob vyžaduje vaši účast při každém přihlášení. Když přihlášení vyprší, '
              'Datovka schránku jen označí a počká, až se přihlásíte sami. Nebude otevírat okna '
              'ani posílat upozornění.',
              style: text.bodySmall?.copyWith(color: t.ink),
            ),
          ),
        const SizedBox(height: 16),
        if (method != LoginMethod.certificate)
          TextField(
            controller: secret,
            obscureText: true,
            decoration: InputDecoration(
              labelText: method == LoginMethod.mobileKey
                  ? 'Komunikační kód mobilního klíče'
                  : 'Heslo (uloží se pro automatické stahování)',
              helperText: method == LoginMethod.mobileKey
                  ? 'Najdete ho na portálu datových schránek v nastavení mobilního klíče.'
                  : passwordHelper ??
                        'Nechte prázdné, pokud heslo nechcete ukládat.',
              helperMaxLines: 2,
            ),
          )
        else
          Text(
            'Soubor s certifikátem (.p12, .pfx) vyberete při přihlášení.',
            style: text.bodySmall,
          ),
      ],
    );
  }
}

/// Changes how [box] logs in, then offers the login right away when the box
/// is not logged in, so the new method can be used without a restart.
Future<void> showChangeLoginDialog(BuildContext context, DataBox box) async {
  final s = AppScope.of(context);
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _ChangeLoginDialog(box),
  );
  if (saved != true || !context.mounted) return;
  final now = s.boxById(box.id);
  if (now != null && now.session != Session.active) {
    await showLoginDialog(context, now);
  }
}

class _ChangeLoginDialog extends StatefulWidget {
  final DataBox box;

  const _ChangeLoginDialog(this.box);

  @override
  State<_ChangeLoginDialog> createState() => _ChangeLoginDialogState();
}

class _ChangeLoginDialogState extends State<_ChangeLoginDialog> {
  final _secret = TextEditingController();
  late var _method = widget.box.login;
  String? _error;

  @override
  void dispose() {
    _secret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: Text('Způsob přihlášení – ${widget.box.name}'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Nyní: ${widget.box.login.label}. Musí odpovídat tomu, co máte '
                'nastavené na portálu datových schránek. Po změně se ke '
                'schránce přihlásíte znovu.',
                style: text.bodySmall,
              ),
              const SizedBox(height: 12),
              LoginMethodFields(
                method: _method,
                secret: _secret,
                onChanged: (m) => setState(() => _method = m),
                passwordHelper:
                    'Nechte prázdné, pokud se heslo nemění nebo ho nechcete ukládat.',
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(color: Tokens.of(context).danger),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: () async {
            try {
              await AppScope.of(
                context,
              ).changeLogin(widget.box, _method, secret: _secret.text);
              if (context.mounted) Navigator.of(context).pop(true);
            } on Object catch (e) {
              setState(() => _error = '$e');
            }
          },
          child: const Text('Uložit'),
        ),
      ],
    );
  }
}
