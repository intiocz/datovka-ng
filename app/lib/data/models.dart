enum Direction { received, sent }

enum LoginMethod {
  password(
    'Jméno a heslo',
    'Přihlášení i stahování na pozadí bez vaší účasti.',
  ),
  passwordSms(
    'Heslo a SMS kód',
    'Při každém přihlášení přijde kód na telefon.',
  ),
  passwordOtp(
    'Heslo a kód z aplikace',
    'ISDS tento způsob ruší. Přepněte schránku na mobilní klíč nebo SMS.',
  ),
  mobileKey(
    'Mobilní klíč',
    'Přihlášení potvrdíte v aplikaci Mobilní klíč eGovernmentu.',
  ),
  certificate(
    'Certifikát',
    'Systémový nebo komerční certifikát, volitelně s heslem.',
  );

  final String label;
  final String description;

  const LoginMethod(this.label, this.description);

  /// ISDS is ending the code from an app or token (HOTP); a box can keep it
  /// until it changes it, but it is no longer offered.
  bool get retired => this == LoginMethod.passwordOtp;

  /// Methods that need the user at hand for every login. Background sync never
  /// starts such a login on its own.
  bool get interactive =>
      this == LoginMethod.passwordSms ||
      this == LoginMethod.passwordOtp ||
      this == LoginMethod.mobileKey;
}

enum Session { active, expired }

class DataBox {
  final String id;
  final String name;
  final String kind;
  final String username;
  final LoginMethod login;
  final Session session;
  final bool testEnv;

  /// ISDS data box ID (7 characters); [id] is the login username.
  final String? isdsId;

  /// Password (or mobile key communication code) is stored in the data folder.
  final bool storedCredentials;

  const DataBox({
    required this.id,
    required this.name,
    required this.kind,
    required this.username,
    this.login = LoginMethod.password,
    this.session = Session.active,
    this.testEnv = false,
    this.isdsId,
    this.storedCredentials = false,
  });

  /// Whether background sync can download messages for this box right now.
  /// A password box with a stored password counts as logged in; without one,
  /// or with any other method, it needs a login from the user first.
  bool get canSyncUnattended => session == Session.active;

  DataBox copyWith({Session? session, String? name, LoginMethod? login}) =>
      DataBox(
        id: id,
        name: name ?? this.name,
        kind: kind,
        username: username,
        login: login ?? this.login,
        session: session ?? this.session,
        testEnv: testEnv,
        isdsId: isdsId,
        storedCredentials: storedCredentials,
      );
}

class Attachment {
  final String name;
  final int sizeBytes;

  /// Row id in the original database; `null` until the file is loaded.
  final int? id;

  const Attachment(this.name, this.sizeBytes, {this.id});
}

/// Period a message stays in ISDS before its content is deleted.
const isdsRetention = Duration(days: 90);

/// How far the message is dealt with, as the original app keeps it
/// (`process_state`: 0, 1, 2).
enum ProcessState {
  unsettled('Nevyřízeno'),
  inProgress('Vyřizuje se'),
  settled('Vyřízeno');

  final String label;

  const ProcessState(this.label);
}

class Message {
  final String boxId;
  final String dmId;
  final Direction direction;
  final String subject;
  final String counterparty;
  final String counterpartyAddress;

  /// Data box ID of the sender (received) or recipient (sent).
  final String? counterpartyBoxId;
  final DateTime delivered;
  final bool isRead;

  /// `null` until the signature has been checked.
  final bool? signatureValid;
  final String? ourRef;
  final String? theirRef;
  final List<Attachment> attachments;
  final List<String> tags;

  /// Deadline the user set for acting on the message (reply, appeal, payment).
  final DateTime? deadline;

  /// Free note, shared with the original app (`tag.db`).
  final String? note;

  final ProcessState processState;

  /// ISDS marked the message as suspicious (spam, possibly harmful).
  final bool suspicious;

  const Message({
    required this.boxId,
    required this.dmId,
    required this.direction,
    required this.subject,
    required this.counterparty,
    required this.counterpartyAddress,
    this.counterpartyBoxId,
    required this.delivered,
    this.isRead = true,
    this.signatureValid,
    this.ourRef,
    this.theirRef,
    this.attachments = const [],
    this.tags = const [],
    this.deadline,
    this.note,
    this.processState = ProcessState.unsettled,
    this.suspicious = false,
  });

  DateTime get isdsDeletion => delivered.add(isdsRetention);

  Message copyWith({
    bool? isRead,
    DateTime? deadline,
    bool clearDeadline = false,
    List<String>? tags,
    List<Attachment>? attachments,
    String? note,
    bool clearNote = false,
    ProcessState? processState,
  }) => Message(
    boxId: boxId,
    dmId: dmId,
    direction: direction,
    subject: subject,
    counterparty: counterparty,
    counterpartyAddress: counterpartyAddress,
    counterpartyBoxId: counterpartyBoxId,
    delivered: delivered,
    isRead: isRead ?? this.isRead,
    signatureValid: signatureValid,
    ourRef: ourRef,
    theirRef: theirRef,
    attachments: attachments ?? this.attachments,
    tags: tags ?? this.tags,
    deadline: clearDeadline ? null : (deadline ?? this.deadline),
    note: clearNote ? null : (note ?? this.note),
    processState: processState ?? this.processState,
    suspicious: suspicious,
  );
}

/// Another device holds the shared-folder write lock.
class ForeignLock {
  final String device;
  final bool stale;
  final DateTime? heartbeat;

  const ForeignLock({
    required this.device,
    required this.stale,
    this.heartbeat,
  });

  factory ForeignLock.fromJson(Map<String, dynamic> j) => ForeignLock(
    device: j['device'] as String? ?? 'jiné zařízení',
    stale: j['stale'] == true,
    heartbeat: DateTime.tryParse(j['heartbeat'] as String? ?? '')?.toLocal(),
  );
}

enum Folder { inbox, sent, deadlines, all, drafts }

enum Screen { messages, directory }

/// What to search the ISDS data box directory by.
enum DirectoryScope {
  general('Název nebo adresa'),
  ico('IČO'),
  boxId('ID schránky');

  final String label;

  const DirectoryScope(this.label);
}

/// A data box found in the public ISDS directory.
class DirectoryEntry {
  final String boxId;
  final String name;
  final String address;
  final String type;
  final String? ico;
  final bool isAuthority;
  final bool acceptsCommercial;

  const DirectoryEntry({
    required this.boxId,
    required this.name,
    required this.address,
    required this.type,
    this.ico,
    this.isAuthority = false,
    this.acceptsCommercial = false,
  });
}

class SyncState {
  final DateTime? lastSync;
  final bool running;
  final String storageName;

  /// Boxes skipped by the last sync because they wait for an interactive login.
  final List<String> skipped;

  /// Number of messages the last sync downloaded.
  final int lastNew;

  const SyncState({
    this.lastSync,
    this.running = false,
    this.storageName = 'iCloud Drive',
    this.skipped = const [],
    this.lastNew = 0,
  });
}

/// Advanced search criteria.
class SearchFilter {
  final DateTime? from;
  final DateTime? to;
  final bool unreadOnly;
  final bool withDeadline;
  final String? tag;

  const SearchFilter({
    this.from,
    this.to,
    this.unreadOnly = false,
    this.withDeadline = false,
    this.tag,
  });

  bool get active =>
      from != null || to != null || unreadOnly || withDeadline || tag != null;

  /// Active beyond a year or month picked by the period button.
  bool get activeBesidesPeriod =>
      (period == null && (from != null || to != null)) ||
      unreadOnly ||
      withDeadline ||
      tag != null;

  /// The same filter for another date range; `null` for no limit.
  SearchFilter withRange(DateTime? from, DateTime? to) => SearchFilter(
    from: from,
    to: to,
    unreadOnly: unreadOnly,
    withDeadline: withDeadline,
    tag: tag,
  );

  /// The year or month the date range covers exactly, if it does.
  ({int year, int? month})? get period {
    final f = from, t = to;
    if (f == null || t == null || f.day != 1 || f.year != t.year) return null;
    if (f.month == 1 && t.month == 12 && t.day == 31) {
      return (year: f.year, month: null);
    }
    final last = DateTime(f.year, f.month + 1, 0).day;
    if (f.month == t.month && t.day == last) {
      return (year: f.year, month: f.month);
    }
    return null;
  }
}

/// Someone the user corresponds with, derived from stored messages.
class Contact {
  final String boxId;
  final String name;
  final String address;

  /// Number of received and sent messages with them.
  final int count;

  /// Time of the latest message with them.
  final DateTime last;

  const Contact({
    required this.boxId,
    required this.name,
    required this.address,
    required this.count,
    required this.last,
  });
}

/// A stored message whose qualified time stamp expires soon.
class StampExpiry {
  final DataBox box;
  final String dmId;
  final DateTime expires;
  final String subject;
  final String counterparty;
  final bool received;

  const StampExpiry({
    required this.box,
    required this.dmId,
    required this.expires,
    required this.subject,
    required this.counterparty,
    required this.received,
  });

  /// ISDS renews a time stamp only in its last year and a half.
  bool get renewable =>
      expires.difference(DateTime.now()) < const Duration(days: 548);
}
