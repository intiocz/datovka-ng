import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'archive_location.dart';
import 'core_bridge.dart';
import 'data_folder.dart';
import 'mailbox.dart';
import 'models.dart';
import 'settings.dart';
import 'user_error.dart';

LoginMethod _login(String? v) => switch (v) {
  'password_totp' => LoginMethod.passwordSms,
  'password_hotp' => LoginMethod.passwordOtp,
  'mobile_key' => LoginMethod.mobileKey,
  'certificate' => LoginMethod.certificate,
  _ => LoginMethod.password,
};

String _boxKind(String? type) => switch (type) {
  'FO' => 'Fyzická osoba',
  'PFO' ||
  'PFO_ADVOK' ||
  'PFO_DANPOR' ||
  'PFO_INSSPR' ||
  'PFO_AUDITOR' => 'Podnikající fyzická osoba',
  'PO' || 'PO_ZAK' || 'PO_REQ' => 'Právnická osoba',
  'OVM' => 'Orgán veřejné moci',
  null => 'Datová schránka',
  _ => type,
};

/// UI state over the original Datovka archive. Without the native library
/// the lists stay empty.
class AppState extends ChangeNotifier {
  final CoreBridge? core;
  List<DataBox> boxes;
  List<Message> _messages;
  SyncState sync = SyncState(
    lastSync: DateTime.now().subtract(const Duration(minutes: 3)),
  );

  /// Folder with the original Datovka data, when running on real data.
  String? dataDir;

  /// Last error from a user action or from loading the archive.
  String? actionError;
  String? loadError;

  /// Failures of the last download. Kept apart so a reload does not wipe them.
  String? syncError;

  String? get error => actionError ?? loadError;

  /// How many rows the current list asks the core for.
  static const pageSize = 200;
  int _limit = pageSize;
  int listTotal = 0;
  bool listLoading = false;

  /// Bumped on every full reload. Older replies are dropped.
  int _epoch = 0;
  int _listTicket = 0;
  Timer? _searchTimer;

  final Map<String, int> _unread = {};
  final Map<String, int> _deadlines = {};
  List<Contact> _contacts = const [];

  /// Set when a download found another device writing. Reading stays open.
  ForeignLock? foreignLock;

  /// Short line for the status bar when nothing else is running.
  String activity = 'Připraveno';

  /// Messages picked with ⌘/Ctrl-click or Shift-click. Empty means none.
  final Set<String> picked = {};
  String? _pickAnchor;

  final FocusNode searchFocus = FocusNode();
  final TextEditingController searchBox = TextEditingController();

  final Map<String, List<Attachment>> _attachments = {};
  final Map<String, Future<List<Attachment>>> _attachmentLoads = {};

  /// Address book used only when there is no core. The real app asks ISDS.
  final List<DirectoryEntry> _sampleDirectory;

  AppState({
    this.core,
    bool autoSync = true,
    List<DataBox> initialBoxes = const [],
    List<Message> messages = const [],
    List<DirectoryEntry> directory = const [],
  }) : boxes = core == null ? initialBoxes : const [],
       _messages = core == null ? messages : const [],
       _sampleDirectory = core == null ? directory : const [] {
    if (core != null) {
      reload();
      // Quietly download new messages: at start and every 15 minutes. Only
      // boxes that can log in without the user are contacted.
      if (autoSync) {
        Settings.load().then((st) {
          applySettings(st, initial: true);
        });
      }
    }
  }

  Timer? _timer;
  Settings settings = const Settings();

  /// Applies preferences; restarts the automatic download timer.
  void applySettings(Settings st, {bool initial = false}) {
    settings = st;
    try {
      core?.call('set_proxy', [st.proxy]);
    } on Object catch (e) {
      actionError = '$e';
    }
    _timer?.cancel();
    _timer = null;
    if (core == null) return;
    if (initial && st.syncOnStart) {
      Future<void>.delayed(const Duration(seconds: 3), runSync);
    }
    if (st.syncMinutes > 0) {
      _timer = Timer.periodic(
        Duration(minutes: st.syncMinutes),
        (_) => runSync(),
      );
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _searchTimer?.cancel();
    searchFocus.dispose();
    searchBox.dispose();
    super.dispose();
  }

  bool get live => core != null;

  /// (Re)reads accounts and messages from the shared databases.
  /// Runs on a background isolate so a slow file (e.g. iCloud still
  /// downloading it) never freezes the window.
  /// Password boxes with a stored password log in by themselves; the others
  /// once the user logged in during this run. Logging out wins over both.
  Session _session(Map<String, dynamic> a, Set<String> live) {
    final user = a['username'] as String;
    if (_loggedOut.contains(user)) return Session.expired;
    final stored =
        _login(a['login'] as String?) == LoginMethod.password &&
        (a['has_credentials'] as bool? ?? false);
    return live.contains(user) || stored ? Session.active : Session.expired;
  }

  Future<void> reload() async {
    final epoch = ++_epoch;
    final c = core;
    if (c == null) return;
    try {
      final res = await c.callAsync('accounts', ['']) as Map<String, dynamic>;
      dataDir = res['dir'] as String?;
      sync = SyncState(
        lastSync: sync.lastSync,
        running: sync.running,
        storageName: ArchiveLocation.storageLabel(dataDir),
        skipped: sync.skipped,
        lastNew: sync.lastNew,
      );
      final accounts = (res['accounts'] as List).cast<Map<String, dynamic>>();
      pinLocked = accounts.any(
        (a) => a['pin_protected'] == true && a['has_credentials'] != true,
      );
      final live = ((await c.callAsync('sessions', [])) as List)
          .cast<String>()
          .toSet();
      boxes = [
        for (final a in accounts)
          DataBox(
            id: a['username'] as String,
            name: a['name'] as String? ?? a['username'] as String,
            kind: _boxKind(a['box_type'] as String?),
            username: a['username'] as String,
            login: _login(a['login'] as String?),
            testEnv: a['test_env'] as bool? ?? false,
            isdsId: a['box_id'] as String?,
            // Stored credentials let the box sync unattended, like in the original app.
            storedCredentials: a['has_credentials'] as bool? ?? false,
            session: _session(a, live),
          ),
      ];
      if (epoch != _epoch) return;
      _countDrafts();
      _messages = const [];
      listTotal = 0;
      _attachments.clear();
      _attachmentLoads.clear();
      loadError = null;
    } on Object catch (e) {
      if (epoch != _epoch) return;
      loadError = 'Nepodařilo se načíst data: $e';
      notifyListeners();
      return;
    }
    notifyListeners();
    await _loadList(epoch);
    _refreshTree();
  }

  Map<String, Object?> _listSpec({
    List<String>? usernames,
    String? folderName,
    String queryText = '',
    bool useQuery = true,
    DateTime? from,
    DateTime? to,
    bool useFilter = true,
    int? limit,
  }) {
    String day(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    final fromDay = from ?? (useFilter ? filter.from : null);
    final toDay = to ?? (useFilter ? filter.to : null);
    return {
      'usernames':
          usernames ??
          [if (boxId != null) boxId! else ...boxes.map((b) => b.username)],
      'folder':
          folderName ??
          switch (folder) {
            Folder.inbox => 'inbox',
            Folder.sent => 'sent',
            Folder.deadlines => 'deadlines',
            Folder.all => 'all',
            Folder.drafts => 'drafts',
          },
      'query': correspondentId != null
          ? ''
          : (useQuery ? query : queryText),
      if (correspondentId != null) 'party_box_id': correspondentId,
      if (fromDay != null) 'from': day(fromDay),
      if (toDay != null) 'to': day(toDay),
      'unread_only': useFilter && filter.unreadOnly,
      'with_deadline': useFilter && filter.withDeadline,
      if (useFilter && filter.tag != null) 'tag': filter.tag,
      'limit': limit ?? _limit,
      'offset': 0,
    };
  }

  Future<MailboxPage> _fetchPage(Map<String, Object?> spec) async {
    final raw = await core!.callAsync('message_query', ['', jsonEncode(spec)]);
    return MailboxPage.fromJson((raw as Map).cast<String, dynamic>());
  }

  /// Loads the visible page. [epoch] drops a reply that lost the race.
  Future<void> _loadList(int epoch) async {
    if (core == null) return;
    if (folder == Folder.drafts) return;
    final ticket = ++_listTicket;
    listLoading = true;
    notifyListeners();
    try {
      final page = await _fetchPage(_listSpec());
      if (epoch != _epoch || ticket != _listTicket) return;
      _messages = page.messages;
      listTotal = page.total;
      _unread
        ..clear()
        ..addAll(page.unread);
      _deadlines
        ..clear()
        ..addAll(page.deadlines);
      _contacts = page.contacts;
      allTags = page.allTags;
      _months = page.months;
      loadError = null;
    } on Object catch (e) {
      if (epoch != _epoch || ticket != _listTicket) return;
      _messages = const [];
      listTotal = 0;
      loadError = 'Nepodařilo se načíst zprávy: $e';
    }
    if (epoch != _epoch || ticket != _listTicket) return;
    listLoading = false;
    notifyListeners();
  }

  void _scheduleList() {
    if (!live) {
      notifyListeners();
      return;
    }
    _searchTimer?.cancel();
    _searchTimer = Timer(
      const Duration(milliseconds: 200),
      () => _loadList(_epoch),
    );
    notifyListeners();
  }

  /// Clears a lock left by a device that is no longer writing, then downloads.
  Future<void> takeOverLock() async {
    final c = core;
    if (c == null) return;
    try {
      await c.callAsync('lock', ['', 'take', c.deviceName]);
      foreignLock = null;
      syncError = null;
    } on Object catch (e) {
      actionError = 'Zámek se nepodařilo převzít: $e';
      notifyListeners();
      return;
    }
    notifyListeners();
    await runSync();
  }

  /// All tag names, for suggestions.
  List<String> allTags = const [];

  /// Saves the note of [m]; an empty text removes it.
  void setNote(Message m, String text) {
    final c = core;
    final box = boxById(m.boxId);
    final note = text.trim();
    if (c != null && box != null) {
      try {
        localOp(box, 'set_note', {
          'dm_id': m.dmId,
          'note': note,
          'device': c.deviceName,
        });
      } on Object catch (e) {
        actionError = '$e';
        notifyListeners();
        return;
      }
    }
    _messages = [
      for (final x in _messages)
        x.dmId == m.dmId && x.boxId == m.boxId
            ? x.copyWith(note: note, clearNote: note.isEmpty)
            : x,
    ];
    notifyListeners();
  }

  void setTag(Message m, String tag, bool on) {
    final c = core;
    final box = boxById(m.boxId);
    if (c != null && box != null) {
      try {
        localOp(box, 'set_tag', {
          'dm_id': m.dmId,
          'tag': tag,
          'on': on,
          'device': c.deviceName,
        });
      } on Object catch (e) {
        actionError = '$e';
      }
    }
    if (on && !allTags.contains(tag)) allTags = [...allTags, tag]..sort();
    _messages = [
      for (final x in _messages)
        x.dmId == m.dmId && x.boxId == m.boxId
            ? x.copyWith(
                tags: on
                    ? {...x.tags, tag}.toList()
                    : x.tags.where((t) => t != tag).toList(),
              )
            : x,
    ];
    notifyListeners();
  }

  /// Imports ZFO files into the boxes they belong to; returns a summary.
  Future<String> importZfo(List<String> paths) async {
    final c = core;
    if (c == null) return 'Import funguje jen v desktopové aplikaci.';
    var added = 0;
    final problems = <String>[];
    for (final p in paths) {
      try {
        final r =
            c.call('import_zfo', ['', p, c.deviceName]) as Map<String, dynamic>;
        if (r['added'] == true) added++;
      } on Object catch (e) {
        problems.add('${p.split('/').last}: $e');
      }
    }
    reload();
    return ['Importováno zpráv: $added', ...problems].join('\n');
  }

  /// Asks ISDS whether a ZFO file is authentic (any logged-in box).
  Future<bool> authenticateFile(String path) async {
    final box = searchAccount;
    if (box == null) {
      throw UserError('Pro ověření je potřeba přihlášená schránka.');
    }
    return await op(box, 'authenticate_file', {'path': path}) == true;
  }

  /// Password expiry per box, refreshed after syncing.
  final Map<String, DateTime> passwordExpiry = {};

  /// Names already known. Real rows arrive from [loadAttachments].
  List<Attachment> attachmentsOf(Message m) =>
      _attachments[m.dmId] ?? m.attachments;

  /// Reads attachment names off the UI thread and caches them.
  Future<List<Attachment>> loadAttachments(Message m) {
    final cached = _attachments[m.dmId];
    if (cached != null) return Future.value(cached);
    final c = core;
    if (c == null) return Future.value(m.attachments);
    return _attachmentLoads.putIfAbsent(m.dmId, () async {
      try {
        final rows = ((await c.callAsync('attachments', [
          '',
          m.boxId,
          int.parse(m.dmId),
        ])) as List).cast<Map<String, dynamic>>();
        final list = [
          for (final r in rows)
            Attachment(
              r['file_name'] as String,
              (r['size'] as num?)?.toInt() ?? 0,
              id: (r['id'] as num).toInt(),
            ),
        ];
        _attachments[m.dmId] = list;
        notifyListeners();
        return list;
      } on Object catch (e) {
        actionError = 'Přílohy se nepodařilo načíst: $e';
        _attachments[m.dmId] = const [];
        notifyListeners();
        return const <Attachment>[];
      } finally {
        _attachmentLoads.remove(m.dmId);
      }
    });
  }

  /// Writes an attachment to a temporary file and returns its path.
  String? attachmentFile(Message m, Attachment a) {
    final c = core;
    if (c == null || a.id == null) return null;
    try {
      final path = c.tempPath('${m.dmId}_${a.name}');
      c.call('save_attachment', ['', m.boxId, int.parse(m.dmId), a.id!, path]);
      return path;
    } on Object catch (e) {
      actionError = 'Přílohu se nepodařilo načíst: $e';
      notifyListeners();
      return null;
    }
  }

  /// Opens an attachment in the system's default application.
  Future<void> openAttachment(Message m, Attachment a) async {
    final path = attachmentFile(m, a);
    if (path != null) await core!.openFile(path);
  }

  /// Saves the signed message to [path] (or a temp file that is then revealed).
  Future<String?> saveZfo(Message m, [String? path]) async {
    final c = core;
    if (c == null) return null;
    try {
      final out = path ?? c.tempPath('DZ_${m.dmId}.zfo');
      c.call('save_zfo', ['', m.boxId, int.parse(m.dmId), out]);
      return out;
    } on Object catch (e) {
      actionError = 'ZFO se nepodařilo uložit: $e';
      notifyListeners();
      return null;
    }
  }

  void _persistRead(Message m, bool read) {
    final c = core;
    if (c == null || m.direction != Direction.received) return;
    try {
      c.call('set_read', ['', m.boxId, int.parse(m.dmId), read, c.deviceName]);
    } on Object catch (e) {
      actionError = '$e';
    }
    final box = boxById(m.boxId);
    if (read &&
        settings.markReadInIsds &&
        box != null &&
        box.session == Session.active) {
      // Best effort; the local flag is what the app shows.
      op(box, 'mark_read', {'dm_id': m.dmId}).catchError((_) => null);
    }
  }

  void dismissError() {
    actionError = null;
    loadError = null;
    notifyListeners();
  }

  String? boxId;
  Screen view = Screen.messages;
  Folder folder = Folder.inbox;
  String query = '';

  /// Data-box id of the contact whose correspondence is on screen.
  String? correspondentId;
  String correspondentLabel = '';
  String? selectedId;

  DataBox? boxById(String id) => boxes.where((b) => b.id == id).firstOrNull;

  Message? get selected =>
      _messages.where((m) => m.dmId == selectedId).firstOrNull;

  int unreadIn(String? box) {
    if (live) {
      if (box == null) return _unread.values.fold(0, (a, b) => a + b);
      return _unread[box] ?? 0;
    }
    return _messages
        .where((m) => m.direction == Direction.received && !m.isRead)
        .where((m) => box == null || m.boxId == box)
        .length;
  }

  /// Messages with a deadline in the chosen box, or in all of them.
  int get openDeadlines => live
      ? (boxId == null
            ? _deadlines.values.fold(0, (a, b) => a + b)
            : _deadlines[boxId] ?? 0)
      : _messages
            .where((m) => m.deadline != null)
            .where((m) => boxId == null || m.boxId == boxId)
            .length;

  bool get canLoadMore => live && _messages.length < listTotal;

  void loadMore() {
    if (!canLoadMore) return;
    _limit += pageSize;
    _loadList(_epoch);
  }

  List<Message> get visible => live
      ? _messages
      : visibleMessages(
          messages: _messages,
          boxId: boxId,
          folder: folder,
          query: correspondentId != null ? '' : query,
          filter: filter,
          partyBoxId: correspondentId,
        );

  /// Advanced search filters on top of the text search.
  SearchFilter filter = const SearchFilter();

  Map<String, int> _months = const {};

  /// `YYYY-MM` → messages in the current view, whatever period is chosen.
  Map<String, int> get months {
    if (live) return _months;
    final out = <String, int>{};
    for (final m in visibleMessages(
      messages: _messages,
      boxId: boxId,
      folder: folder,
      query: correspondentId != null ? '' : query,
      filter: filter.withRange(null, null),
      partyBoxId: correspondentId,
    )) {
      final k =
          '${m.delivered.year.toString().padLeft(4, '0')}-'
          '${m.delivered.month.toString().padLeft(2, '0')}';
      out[k] = (out[k] ?? 0) + 1;
    }
    return out;
  }

  /// Shows one year, one month of it, or everything (`year == null`).
  void showPeriod(int? year, [int? month]) {
    if (year == null) return setFilter(filter.withRange(null, null));
    final from = DateTime(year, month ?? 1);
    final to = month == null
        ? DateTime(year, 12, 31)
        : DateTime(year, month + 1, 0);
    setFilter(filter.withRange(from, to));
  }

  void setFilter(SearchFilter f) {
    filter = f;
    _limit = pageSize;
    if (live) {
      _loadList(_epoch);
    } else {
      notifyListeners();
    }
  }

  /// Messages in a date range for the correspondence overview, as CSV.
  Future<String> correspondenceCsv({
    String? box,
    DateTime? from,
    DateTime? to,
  }) async {
    String q(String? v) => '"${(v ?? '').replaceAll('"', '""')}"';
    final List<Message> rows;
    if (live) {
      final page = await _fetchPage(
        _listSpec(
          usernames: [
            if (box != null) box else ...boxes.map((b) => b.username),
          ],
          folderName: 'all',
          useQuery: false,
          from: from,
          to: to,
          useFilter: false,
          limit: 0,
        ),
      );
      rows = [...page.messages]
        ..sort((a, b) => a.delivered.compareTo(b.delivered));
    } else {
      rows = _messages.where((m) {
        if (box != null && m.boxId != box) return false;
        if (from != null && m.delivered.isBefore(from)) return false;
        if (to != null &&
            !m.delivered.isBefore(to.add(const Duration(days: 1)))) {
          return false;
        }
        return true;
      }).toList()..sort((a, b) => a.delivered.compareTo(b.delivered));
    }
    final out = StringBuffer(
      'Datum;Směr;Schránka;ID zprávy;Odesílatel/adresát;ID schránky protistrany;Věc;Č. j. odesílatele;Naše č. j.;Štítky;Lhůta\r\n',
    );
    for (final m in rows) {
      out.write(
        [
          q(
            m.delivered
                .toIso8601String()
                .substring(0, 16)
                .replaceFirst('T', ' '),
          ),
          q(m.direction == Direction.received ? 'přijatá' : 'odeslaná'),
          q(boxById(m.boxId)?.name ?? m.boxId),
          q(m.dmId),
          q(m.counterparty),
          q(m.counterpartyBoxId),
          q(m.subject),
          q(m.theirRef),
          q(m.ourRef),
          q(m.tags.join(', ')),
          q(m.deadline?.toIso8601String().substring(0, 10)),
        ].join(';'),
      );
      out.write('\r\n');
    }
    return out.toString();
  }

  void selectBox(String? id) {
    boxId = id;
    view = Screen.messages;
    selectedId = null;
    picked.clear();
    _limit = pageSize;
    _refreshTree();
    if (live) {
      _loadList(_epoch);
    } else {
      notifyListeners();
    }
  }

  /// Folders and years open in the sidebar tree: `inbox`, `inbox/2025`.
  final treeOpen = <String>{};
  final Map<Folder, Map<String, int>> _tree = {};

  /// `YYYY-MM` → messages of [f] in the chosen box, for the tree; null while
  /// loading. Search and filters do not change it.
  Map<String, int>? treeMonths(Folder f) {
    if (!live) return _monthsOf(f);
    return _tree[f];
  }

  Map<String, int> _monthsOf(Folder f) {
    final out = <String, int>{};
    for (final m in visibleMessages(
      messages: _messages,
      boxId: boxId,
      folder: f,
      query: '',
      filter: const SearchFilter(),
    )) {
      final k =
          '${m.delivered.year.toString().padLeft(4, '0')}-'
          '${m.delivered.month.toString().padLeft(2, '0')}';
      out[k] = (out[k] ?? 0) + 1;
    }
    return out;
  }

  void toggleTree(String key) {
    if (!treeOpen.remove(key)) {
      treeOpen.add(key);
      final f = Folder.values.where((f) => f.name == key).firstOrNull;
      if (f != null && live) _loadTree(f);
    }
    notifyListeners();
  }

  Future<void> _loadTree(Folder f) async {
    final box = boxId;
    try {
      final page = await _fetchPage(
        _listSpec(
          folderName: switch (f) {
            Folder.inbox => 'inbox',
            Folder.sent => 'sent',
            _ => 'all',
          },
          useQuery: false,
          useFilter: false,
          limit: 1,
        ),
      );
      if (box != boxId) return;
      _tree[f] = page.months;
      notifyListeners();
    } on Object {
      // The tree stays as it was; the list shows the error.
    }
  }

  /// New counts for the open folders, after a sync or another box.
  void _refreshTree() {
    _tree.clear();
    if (!live) return;
    for (final f in Folder.values) {
      if (treeOpen.contains(f.name)) _loadTree(f);
    }
  }

  /// A folder of the tree, whole or one year or month of it.
  void openPeriod(Folder f, int? year, [int? month]) {
    view = Screen.messages;
    folder = f;
    selectedId = null;
    picked.clear();
    showPeriod(year, month);
  }

  void selectFolder(Folder f) {
    view = Screen.messages;
    folder = f;
    selectedId = null;
    picked.clear();
    _limit = pageSize;
    if (live && f != Folder.drafts) {
      _loadList(_epoch);
    } else {
      notifyListeners();
    }
  }

  void search(String q) {
    if (searchBox.text != q) {
      searchBox.value = TextEditingValue(
        text: q,
        selection: TextSelection.collapsed(offset: q.length),
      );
    }
    if (correspondentId != null && q == correspondentLabel) {
      query = '';
    } else {
      correspondentId = null;
      correspondentLabel = '';
      query = q;
    }
    _limit = pageSize;
    _scheduleList();
  }

  /// Received messages from [c] and messages sent to [c].
  void messagesWith(Contact c) {
    view = Screen.messages;
    folder = Folder.all;
    boxId = null;
    selectedId = null;
    picked.clear();
    correspondentId = c.boxId;
    correspondentLabel = c.name.isEmpty ? c.boxId : c.name;
    query = '';
    _limit = pageSize;
    if (searchBox.text != correspondentLabel) {
      searchBox.value = TextEditingValue(
        text: correspondentLabel,
        selection: TextSelection.collapsed(offset: correspondentLabel.length),
      );
    }
    _scheduleList();
  }

  void open(String dmId) {
    selectedId = dmId;
    picked.clear();
    _update(dmId, (m) {
      if (m.isRead) return m;
      _persistRead(m, true);
      _adjustUnread(m, -1);
      return m.copyWith(isRead: true);
    });
  }

  /// ⌘/Ctrl-click toggles one row. Shift-click selects the range.
  void pick(Message m, {required bool range}) {
    if (range && _pickAnchor != null) {
      final ids = visible.map((e) => e.dmId).toList();
      final a = ids.indexOf(_pickAnchor!);
      final b = ids.indexOf(m.dmId);
      if (a >= 0 && b >= 0) {
        final lo = a < b ? a : b;
        final hi = a > b ? a : b;
        picked
          ..clear()
          ..addAll(ids.sublist(lo, hi + 1));
        notifyListeners();
        return;
      }
    }
    _pickAnchor = m.dmId;
    if (!picked.add(m.dmId)) picked.remove(m.dmId);
    notifyListeners();
  }

  void clearPicked() {
    if (picked.isEmpty) return;
    picked.clear();
    notifyListeners();
  }

  void moveSelection(int delta) {
    final list = visible;
    if (list.isEmpty) return;
    var i = list.indexWhere((m) => m.dmId == selectedId);
    if (i < 0) i = delta < 0 ? list.length : -1;
    final n = (i + delta).clamp(0, list.length - 1);
    open(list[n].dmId);
  }

  void markPickedRead() {
    final ids = {...picked};
    if (ids.isEmpty && selectedId != null) ids.add(selectedId!);
    for (final id in ids) {
      final m = _messages.where((x) => x.dmId == id).firstOrNull;
      if (m == null || m.isRead || m.direction != Direction.received) continue;
      _persistRead(m, true);
      _adjustUnread(m, -1);
      _messages = [
        for (final x in _messages)
          if (x.dmId == id) x.copyWith(isRead: true) else x,
      ];
    }
    picked.clear();
    notifyListeners();
  }

  void _adjustUnread(Message m, int delta) {
    if (!live || m.direction != Direction.received || delta == 0) return;
    _unread[m.boxId] = (_unread[m.boxId] ?? 0) + delta;
  }

  void close() {
    selectedId = null;
    notifyListeners();
  }

  void toggleRead(String dmId) => _update(dmId, (m) {
    final next = !m.isRead;
    _persistRead(m, next);
    if (m.direction == Direction.received) _adjustUnread(m, next ? -1 : 1);
    return m.copyWith(isRead: next);
  });

  /// Nevyřízeno / vyřizuje se / vyřízeno, shared with the original app.
  void setProcessState(Message m, ProcessState state) {
    final box = boxById(m.boxId);
    final c = core;
    if (c != null && box != null) {
      try {
        localOp(box, 'process_state', {
          'dm_id': m.dmId,
          'state': state.index,
          'device': c.deviceName,
        });
      } on Object catch (e) {
        actionError = '$e';
        notifyListeners();
        return;
      }
    }
    _update(m.dmId, (x) => x.copyWith(processState: state));
  }

  /// Removes the message from this archive only; ISDS keeps it until it
  /// deletes it itself.
  void deleteLocal(Message m) {
    final box = boxById(m.boxId);
    final c = core;
    if (c != null && box != null) {
      localOp(box, 'delete_local', {'dm_id': m.dmId, 'device': c.deviceName});
    }
    if (m.direction == Direction.received && !m.isRead) _adjustUnread(m, -1);
    _messages = [for (final x in _messages) if (x.dmId != m.dmId) x];
    _attachments.remove(m.dmId);
    if (listTotal > 0) listTotal -= 1;
    if (selectedId == m.dmId) selectedId = null;
    picked.remove(m.dmId);
    notifyListeners();
  }

  /// Downloads the message from ISDS again and replaces the stored copy.
  Future<void> redownload(Message m) async {
    final box = boxById(m.boxId);
    if (box == null) return;
    await op(box, 'redownload', {
      'dm_id': m.dmId,
      'incoming': m.direction == Direction.received,
    });
    _attachments.remove(m.dmId);
    if (live) await _loadList(_epoch);
  }

  void setDeadline(String dmId, DateTime? deadline) {
    final m = _messages.where((x) => x.dmId == dmId).firstOrNull;
    final box = m == null ? null : boxById(m.boxId);
    final c = core;
    if (c != null && box != null) {
      try {
        localOp(box, 'set_deadline', {
          'dm_id': dmId,
          'deadline': deadline?.toIso8601String().substring(0, 10),
          'device': c.deviceName,
        });
      } on Object catch (e) {
        actionError = '$e';
      }
    }
    if (live && m != null && (m.deadline != null) != (deadline != null)) {
      _deadlines[m.boxId] = (_deadlines[m.boxId] ?? 0) + (deadline == null ? -1 : 1);
    }
    _setDeadlineLocal(dmId, deadline);
  }

  void _setDeadlineLocal(String dmId, DateTime? deadline) {
    _update(
      dmId,
      (m) => deadline == null
          ? m.copyWith(clearDeadline: true)
          : m.copyWith(deadline: deadline),
    );
    if (live &&
        deadline == null &&
        (folder == Folder.deadlines || filter.withDeadline)) {
      _messages = [for (final m in _messages) if (m.dmId != dmId) m];
      if (listTotal > 0) listTotal -= 1;
      notifyListeners();
    }
  }

  void _update(String dmId, Message Function(Message) f) {
    _messages = [for (final m in _messages) m.dmId == dmId ? f(m) : m];
    notifyListeners();
  }

  /// Boxes whose session expired and which need the user to log in again.
  List<DataBox> get needLogin =>
      boxes.where((b) => !b.canSyncUnattended).toList();

  /// Downloads new messages for every box that can log in without the user.
  ///
  /// Boxes with an interactive login method (SMS, OTP, mobile key) and an
  /// expired session are skipped silently: no dialog, no focus change, no
  /// notification. They are listed in the UI until the user logs in.
  Future<void> runSync() async {
    if (sync.running) return;
    final c = core;
    sync = SyncState(
      lastSync: sync.lastSync,
      running: true,
      skipped: sync.skipped,
    );
    notifyListeners();
    if (c == null) {
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      sync = SyncState(
        lastSync: DateTime.now(),
        skipped: [
          for (final b in boxes)
            if (!b.canSyncUnattended) b.id,
        ],
      );
      notifyListeners();
      return;
    }
    // Only boxes that log in without the user; others are skipped silently.
    final errors = <String>[];
    final skipped = <String>[];
    var fresh = 0;
    for (final b in boxes) {
      if (b.session != Session.active) {
        skipped.add(b.id);
        continue;
      }
      try {
        final r = await c.callAsync('sync', [
          '',
          b.username,
          c.deviceName,
        ]) as Map<String, dynamic>;
        fresh += (r['new_received'] as int) + (r['new_sent'] as int);
        if (b.login == LoginMethod.password &&
            !passwordExpiry.containsKey(b.id)) {
          try {
            final exp = await c.callAsync('op', [
              '',
              b.username,
              'password_expiry',
              '{}',
            ]);
            final d = exp == null ? null : DateTime.tryParse('$exp');
            if (d != null) passwordExpiry[b.id] = d.toLocal();
          } on Object {
            // Expiry is informative only.
          }
        }
        for (final e in (r['errors'] as List)) {
          errors.add('${b.name}: $e');
        }
      } on Object catch (e) {
        if (_expired(b, e)) {
          skipped.add(b.id);
        } else {
          errors.add('${b.name}: $e');
        }
      }
    }
    await reload();
    sync = SyncState(
      lastSync: DateTime.now(),
      skipped: skipped,
      lastNew: fresh,
      storageName: ArchiveLocation.storageLabel(dataDir ?? CoreBridge.dataDir),
    );
    activity = errors.isEmpty ? 'Připraveno' : 'Stahování se nepovedlo';
    syncError = errors.isEmpty ? null : errors.join('\n');
    final blocked = errors.any(
      (e) => e.contains('zapisuje') || e.contains('upravuje'),
    );
    if (!blocked) {
      foreignLock = null;
    } else {
      try {
        final st =
            (await c.callAsync('lock', ['', 'status', c.deviceName]) as Map)
                .cast<String, dynamic>();
        foreignLock = st['held'] == true && st['ours'] != true
            ? ForeignLock.fromJson(st)
            : null;
      } on Object {
        foreignLock = null;
      }
    }
    notifyListeners();
  }

  /// Points the app at a Datovka folder (the iCloud one on a phone).
  Future<void> useDataDir(String dir) async {
    CoreBridge.dataDir = dir;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('dataDir', dir);
    await DataFolder.remember(dir);
    await DataFolder.materialize(dir);
    await reload();
  }

  /// Completes a login the user started. Only ever called from user actions.
  void loggedIn(String boxId) {
    _loggedOut.remove(boxId);
    boxes = [
      for (final b in boxes)
        b.id == boxId ? b.copyWith(session: Session.active) : b,
    ];
    sync = SyncState(
      lastSync: sync.lastSync,
      skipped: sync.skipped.where((id) => id != boxId).toList(),
    );
    notifyListeners();
  }

  /// Moves a box to [newIndex] (index after removal) and saves the order.
  void moveBox(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    final list = [...boxes];
    list.insert(newIndex, list.removeAt(oldIndex));
    boxes = list;
    notifyListeners();
    final c = core;
    if (c == null) return;
    try {
      c.call('reorder', [
        '',
        jsonEncode([for (final b in boxes) b.username]),
        c.deviceName,
      ]);
    } on Object catch (e) {
      actionError = 'Pořadí se nepodařilo uložit: $e';
      notifyListeners();
    }
  }

  static const _loginNames = {
    LoginMethod.password: 'password',
    LoginMethod.passwordSms: 'password_totp',
    LoginMethod.passwordOtp: 'password_hotp',
    LoginMethod.mobileKey: 'mobile_key',
    LoginMethod.certificate: 'certificate',
  };

  /// Adds a box to the shared configuration; [secret] is the password or the
  /// mobile key communication code.
  void addBox(DataBox box, {String secret = ''}) {
    final c = core;
    if (c == null) {
      boxes = [...boxes, box];
      notifyListeners();
      return;
    }
    c.call('account_add', [
      '',
      jsonEncode({
        'name': box.name,
        'username': box.username,
        'login': _loginNames[box.login],
        'secret': secret,
        'test_env': box.testEnv,
      }),
      c.deviceName,
    ]);
    reload();
  }

  /// Switches how [box] logs in. A non-empty [secret] is stored as the
  /// password, or as the mobile key code. The box has to log in again.
  Future<void> changeLogin(
    DataBox box,
    LoginMethod login, {
    String secret = '',
  }) async {
    final c = core;
    if (c != null) {
      c.call('account_set_login', [
        '',
        box.username,
        jsonEncode({'login': _loginNames[login], 'secret': secret}),
        c.deviceName,
      ]);
      await reload();
      return;
    }
    boxes = [
      for (final b in boxes)
        if (b.id == box.id)
          b.copyWith(login: login, session: Session.expired)
        else
          b,
    ];
    notifyListeners();
  }

  /// Saves a new list name. The official name in ISDS stays as it is.
  void renameBox(DataBox box, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.contains('\n') || trimmed.contains('\r')) {
      actionError = 'Jméno schránky nesmí být prázdné.';
      notifyListeners();
      return;
    }
    final c = core;
    if (c != null) {
      try {
        c.call('account_rename', ['', box.username, trimmed, c.deviceName]);
      } on Object catch (e) {
        actionError = 'Schránku se nepodařilo přejmenovat: $e';
        notifyListeners();
        return;
      }
    }
    boxes = [
      for (final b in boxes)
        if (b.id == box.id) b.copyWith(name: trimmed) else b,
    ];
    notifyListeners();
  }

  /// Removes a box from the configuration; its archive stays on disk.
  void removeBox(DataBox box) {
    final c = core;
    if (c != null) c.call('account_remove', ['', box.username, c.deviceName]);
    if (boxId == box.id) boxId = null;
    if (c == null) {
      boxes = boxes.where((b) => b.id != box.id).toList();
      notifyListeners();
    } else {
      reload();
    }
  }

  // Data box directory (ISDS search).

  DirectoryScope directoryScope = DirectoryScope.general;
  String directoryQuery = '';
  bool authoritiesOnly = false;
  List<DirectoryEntry>? directoryResults;
  bool directoryBusy = false;

  void openDirectory() {
    view = Screen.directory;
    selectedId = null;
    notifyListeners();
  }

  void setDirectoryScope(DirectoryScope scope) {
    directoryScope = scope;
    notifyListeners();
  }

  void setAuthoritiesOnly(bool v) {
    authoritiesOnly = v;
    if (directoryQuery.isNotEmpty) searchDirectory(directoryQuery);
    notifyListeners();
  }

  int _searchSeq = 0;
  int directoryTotal = 0;

  /// Box used to log in for directory searches: the selected one when it can
  /// log in unattended, otherwise the first such box.
  DataBox? get searchAccount {
    final sel = boxId == null ? null : boxById(boxId!);
    if (sel != null && _canLogIn(sel)) return sel;
    return boxes.where(_canLogIn).firstOrNull;
  }

  bool _canLogIn(DataBox b) => b.session == Session.active;

  /// An expired interactive session: mark the box quietly, no error banner.
  bool _expired(DataBox b, Object e) {
    if (!'$e'.startsWith('session_expired')) return false;
    boxes = [
      for (final x in boxes)
        x.id == b.id ? x.copyWith(session: Session.expired) : x,
    ];
    return true;
  }

  // Interactive login, only ever started by the user.

  /// Password + code. With [sms] and no [code], ISDS sends an SMS; returns
  /// `true` when logged in, `false` when the SMS was sent.
  /// Name and password login: ISDS checks the password and it is kept in the
  /// password store of this device, so next time the box logs in by itself.
  Future<void> loginPassword(DataBox b, String password) async {
    final c = core;
    if (c != null) {
      await c.callAsync('login_password', ['', b.username, password]);
    }
    loggedIn(b.id);
    if (c != null) unawaited(reload());
    unawaited(runSync());
  }

  Future<bool> loginWithCode(
    DataBox b, {
    String password = '',
    String code = '',
    bool sms = false,
  }) async {
    final c = core;
    if (c == null) {
      if (code.isEmpty && sms) return false;
      loggedIn(b.id);
      return true;
    }
    final r = await c.callAsync('login_otp', [
      '',
      b.username,
      password,
      code,
      sms,
    ]) as Map<String, dynamic>;
    if (r['step'] == 'done') {
      loggedIn(b.id);
      unawaited(runSync());
      return true;
    }
    return false;
  }

  /// Logs in with the box's certificate (PKCS#12); [p12Path] overrides the
  /// file from the configuration.
  Future<void> loginCertificate(
    DataBox b,
    String passphrase, {
    String p12Path = '',
  }) async {
    final c = core;
    if (c == null) {
      loggedIn(b.id);
      return;
    }
    await c.callAsync('login_cert', ['', b.username, p12Path, passphrase]);
    loggedIn(b.id);
    unawaited(runSync());
  }

  /// Starts a mobile key login; the phone gets a push notification.
  Future<void> mobileKeyStart(DataBox b) async {
    final c = core;
    if (c == null) return;
    await c.callAsync('login_mep_start', ['', b.username]);
  }

  /// One check whether the login was confirmed in the app.
  Future<bool> mobileKeyPoll(DataBox b) async {
    final c = core;
    if (c == null) {
      await Future<void>.delayed(const Duration(seconds: 2));
      loggedIn(b.id);
      return true;
    }
    final r = await c.callAsync('login_mep_poll', [
      b.username,
    ]) as Map<String, dynamic>;
    if (r['step'] == 'done') {
      loggedIn(b.id);
      unawaited(runSync());
      return true;
    }
    return false;
  }

  /// Ends an interactive session; the box waits quietly for the next login.
  /// Boxes the user logged out of. They stay logged out, stored password or
  /// not, until the user logs in again.
  final Set<String> _loggedOut = {};

  void logout(DataBox b) {
    _loggedOut.add(b.id);
    cancelLogin(b);
    boxes = [
      for (final x in boxes)
        x.id == b.id ? x.copyWith(session: Session.expired) : x,
    ];
    notifyListeners();
  }

  /// Stops a pending login when the user closes the dialog.
  void cancelLogin(DataBox b) {
    try {
      core?.call('logout', [b.username]);
    } on Object {
      // Nothing to cancel.
    }
  }

  Future<void> searchDirectory(String q) async {
    directoryQuery = q.trim();
    final seq = ++_searchSeq;
    if (directoryQuery.length < 3) {
      directoryResults = null;
      directoryBusy = false;
      notifyListeners();
      return;
    }
    directoryBusy = true;
    notifyListeners();
    final c = core;
    if (c == null) {
      final words = foldText(directoryQuery).split(RegExp(r'\s+'))
        ..removeWhere((w) => w.isEmpty);
      directoryResults = _sampleDirectory.where((e) {
        if (authoritiesOnly && !e.isAuthority) return false;
        final hay = switch (directoryScope) {
          DirectoryScope.general => foldText('${e.name} ${e.address}'),
          DirectoryScope.ico => e.ico ?? '',
          DirectoryScope.boxId => e.boxId,
        };
        return words.every(hay.contains);
      }).toList();
      directoryBusy = false;
      notifyListeners();
      return;
    }
    // Wait for a pause in typing before asking ISDS.
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (seq != _searchSeq) return;
    final acc = searchAccount;
    if (acc == null) {
      directoryBusy = false;
      actionError = 'Pro hledání v adresáři je potřeba schránka s uloženým heslem.';
      notifyListeners();
      return;
    }
    try {
      final page = await c.callAsync('search', [
        '',
        acc.username,
        directoryQuery,
        switch (directoryScope) {
          DirectoryScope.general => 'general',
          DirectoryScope.ico => 'ico',
          DirectoryScope.boxId => 'box_id',
        },
        authoritiesOnly,
        0,
      ]) as Map<String, dynamic>;
      if (seq != _searchSeq) return;
      directoryTotal = page['total'] as int? ?? 0;
      directoryResults = [
        for (final e in (page['entries'] as List).cast<Map<String, dynamic>>())
          DirectoryEntry(
            boxId: e['box_id'] as String,
            name: e['name'] as String? ?? '',
            address: e['address'] as String? ?? '',
            type: _boxKind(e['box_type'] as String?),
            ico: e['ico'] as String?,
            isAuthority: e['is_authority'] as bool? ?? false,
            acceptsCommercial: (e['send_options'] as String?) == 'ALL',
          ),
      ];
    } on Object catch (e) {
      if (seq != _searchSeq) return;
      directoryResults = const [];
      actionError = 'Hledání v adresáři selhalo: $e';
    }
    directoryBusy = false;
    notifyListeners();
  }

  // Sending.

  /// Boxes that can send right now (stored password).
  List<DataBox> get sendingBoxes => boxes.where(_canLogIn).toList();

  /// Sends a message to one recipient; returns the new message ID.
  /// [envelope] holds the request fields of `OutgoingMessage` in the core.
  Future<String> send({
    required DataBox from,
    required Map<String, Object?> envelope,
    required List<String> files,
  }) async {
    final c = core;
    if (c == null) {
      throw UserError(
        'V náhledu nelze odesílat, spusťte desktopovou aplikaci.',
      );
    }
    final request = jsonEncode({...envelope, 'files': files});
    final String id;
    try {
      id = await c.callAsync('send', ['', from.username, request]) as String;
    } on Object catch (e) {
      if (_expired(from, e)) {
        notifyListeners();
        throw UserError(
          'Přihlášení ke schránce ${from.name} vypršelo. Přihlaste se a odešlete znovu.',
        );
      }
      rethrow;
    }
    return id;
  }

  /// People and offices from received and sent messages, most frequent
  /// correspondents first; built automatically, nothing to maintain.
  List<Contact> get contacts => live ? _contacts : contactsFrom(_messages);

  /// Contacts matching [q] (all of its words, without diacritics).
  List<Contact> contactsMatching(String q) {
    final words = foldText(q.trim()).split(RegExp(r'\s+'))
      ..removeWhere((w) => w.isEmpty);
    if (words.isEmpty) return contacts;
    return contacts.where((c) {
      final hay = foldText('${c.name} ${c.address} ${c.boxId}');
      return words.every(hay.contains);
    }).toList();
  }

  // Drafts (shared folder).

  /// Sending box of each draft; refreshed on reload and when a draft
  /// changes.
  List<String?> _draftFrom = const [];

  /// Shown next to "Koncepty": drafts of the chosen box, or all of them.
  int get draftCount => boxId == null
      ? _draftFrom.length
      : _draftFrom.where((b) => b == boxId).length;

  void _countDrafts() {
    _draftFrom = [
      for (final d in drafts())
        () {
          try {
            return (jsonDecode(d['content'] as String) as Map)['from']
                as String?;
          } on Object {
            return null;
          }
        }(),
    ];
  }

  List<Map<String, dynamic>> drafts() {
    if (core == null || boxes.isEmpty) return const [];
    try {
      return (localOp(boxes.first, 'drafts', {}) as List)
          .cast<Map<String, dynamic>>();
    } on Object catch (e) {
      actionError = '$e';
      return const [];
    }
  }

  /// Saves a draft for [box]; returns its id.
  int? saveDraft(DataBox box, int? id, String content) {
    final c = core;
    if (c == null) return null;
    final saved =
        localOp(box, 'save_draft', {
              'id': ?id,
              'content': content,
              'device': c.deviceName,
            })
            as int?;
    _countDrafts();
    notifyListeners();
    return saved;
  }

  void deleteDraft(int id) {
    final c = core;
    if (c == null || boxes.isEmpty) return;
    localOp(boxes.first, 'delete_draft', {'id': id, 'device': c.deviceName});
    _countDrafts();
    notifyListeners();
  }

  // Further ISDS operations (see `dk_op` in ffi/src/lib.rs).

  /// Runs an ISDS operation for a box; throws with a readable message.
  /// An expired interactive session marks the box quietly and says so.
  Future<dynamic> op(
    DataBox box,
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    final c = core;
    if (c == null) {
      throw UserError(
        'V náhledu nelze volat ISDS, spusťte desktopovou aplikaci.',
      );
    }
    try {
      return await c.callAsync('op', [
        '',
        box.username,
        name,
        jsonEncode(args),
      ]);
    } on Object catch (e) {
      if (_expired(box, e)) {
        notifyListeners();
        throw UserError(
          'Přihlášení ke schránce ${box.name} vypršelo. Přihlaste se znovu.',
        );
      }
      rethrow;
    }
  }

  /// Local operation without login (delivery info stored in the database).
  dynamic localOp(DataBox box, String name, Map<String, Object?> args) =>
      core?.call('op', ['', box.username, name, jsonEncode(args)]);

  String? tempPath(String name) => core?.tempPath(name);

  Future<String> backup(String target) async {
    final c = core;
    if (c == null) return 'Zálohy fungují jen v desktopové aplikaci.';
    final r = await c.callAsync('backup', ['', target]) as Map<String, dynamic>;
    return 'Záloha uložena (${r['files']} souborů): ${r['path']}';
  }

  Future<String> restore(String backupDir) async {
    final c = core;
    if (c == null) return 'Obnova funguje jen v desktopové aplikaci.';
    final r = await c.callAsync('restore', [
      '',
      backupDir,
      c.deviceName,
    ]) as Map<String, dynamic>;
    reload();
    return 'Obnoveno ${r['files']} souborů. Původní data jsou uložena v ${r['safety_copy']}.';
  }

  /// Stored passwords are PIN-protected and the PIN was not entered yet.
  bool pinLocked = false;

  /// Unlocks PIN-protected passwords for this run; returns false for a wrong PIN.
  bool unlockPin(String pin) {
    final c = core;
    if (c == null) return false;
    final ok = c.call('set_pin', ['', pin]) == true;
    if (ok) {
      reload();
      unawaited(runSync());
    }
    return ok;
  }

  /// Imports all mobile Datovka databases found in [folder] into the boxes
  /// with the same username; returns a summary.
  Future<String> importMobile(String folder) async {
    final c = core;
    if (c == null) return 'Import funguje jen v desktopové aplikaci.';
    final dbs = (c.call('mobile_scan', [folder]) as List)
        .cast<Map<String, dynamic>>();
    if (dbs.isEmpty) return 'Ve složce nejsou databáze mobilní Datovky.';
    final lines = <String>[];
    for (final db in dbs) {
      final user = db['username'] as String;
      if (boxById(user) == null) {
        lines.add('$user: schránka není v DATOVCE přidaná, přeskočeno');
        continue;
      }
      try {
        final r = c.call('mobile_import', [
          '',
          db['path'] as String,
          user,
          c.deviceName,
        ]) as Map;
        lines.add(
          '${boxById(user)!.name}: importováno ${r['imported']}, už bylo ${r['already_present']}'
          '${(r['missing_zfo'] as List).isEmpty ? '' : ', bez originálu ${(r['missing_zfo'] as List).length}'}',
        );
      } on Object catch (e) {
        lines.add('$user: $e');
      }
    }
    reload();
    return lines.join('\n');
  }

  final Map<String, Future<Map<String, dynamic>?>> _signatures = {};

  /// Local verification of the stored original (signature, time stamp,
  /// certificate chain); cached per message.
  Future<Map<String, dynamic>?> signatureOf(Message m) {
    final c = core;
    final box = boxById(m.boxId);
    if (c == null || box == null) return Future.value(null);
    return _signatures.putIfAbsent(
      '${m.boxId}/${m.dmId}',
      () async => ((await c.callAsync('op', [
        '',
        box.username,
        'verify_local',
        jsonEncode({'dm_id': m.dmId}),
      ])) as Map).cast<String, dynamic>(),
    );
  }

  /// Local verification of a ZFO file on disk.
  Future<Map<String, dynamic>> verifyFileLocally(String path) async {
    final c = core;
    if (c == null || boxes.isEmpty) {
      throw UserError('Jen v desktopové aplikaci.');
    }
    return ((await c.callAsync('op', [
      '',
      boxes.first.username,
      'verify_local_file',
      jsonEncode({'path': path}),
    ])) as Map).cast<String, dynamic>();
  }

  // Records management service ("spisová služba", see `dk_rm_*`).

  CoreBridge _rmCore() {
    final c = core;
    if (c == null) {
      throw UserError('Spisová služba funguje jen v desktopové aplikaci.');
    }
    return c;
  }

  /// `{url, configured, encrypted, token_available}`; the token itself never
  /// leaves the core.
  Map<String, dynamic> recordsSettings() {
    final c = core;
    if (c == null) return const {'url': '', 'configured': false};
    return (c.call('rm_settings_get', ['']) as Map).cast<String, dynamic>();
  }

  /// Saves the URL and token (an empty token keeps the stored one, an empty
  /// URL removes the settings).
  void saveRecordsSettings(String url, String token) =>
      _rmCore().call('rm_settings_set', [
        '',
        jsonEncode({'url': url.trim(), 'token': token.trim()}),
      ]);

  /// `{name, token_name, logo_svg}` of the configured service.
  Future<Map<String, dynamic>> recordsServiceInfo() async =>
      ((await _rmCore().callAsync('rm_info', [''])) as Map)
          .cast<String, dynamic>();

  /// Root node of the upload hierarchy (`{name, id, metadata, sub}`).
  Future<Map<String, dynamic>> recordsHierarchy() async =>
      ((await _rmCore().callAsync('rm_hierarchy', [''])) as Map)
          .cast<String, dynamic>();

  /// Uploads the signed message into the chosen nodes; returns the
  /// locations where the service stored it.
  Future<List<String>> uploadToRecords(Message m, List<String> nodeIds) async {
    final box = boxById(m.boxId);
    if (box == null) throw UserError('Neznámá schránka.');
    final r = await _rmCore().callAsync('rm_upload', [
      '',
      box.username,
      int.parse(m.dmId),
      jsonEncode(nodeIds),
    ]) as Map;
    return (r['locations'] as List).cast<String>();
  }

  /// Locations of messages in the service (empty list = not stored).
  Future<Map<String, List<String>>> recordsStored(List<String> dmIds) async {
    final r = await _rmCore().callAsync('rm_stored', [
      '',
      jsonEncode([for (final id in dmIds) int.parse(id)]),
    ]) as List;
    return {
      for (final e in r.cast<Map>())
        '${e['dm_id']}': (e['locations'] as List).cast<String>(),
    };
  }
}
