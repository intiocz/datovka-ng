class CoreBridge {
  static String dataDir = '';

  static CoreBridge? open() => null;

  dynamic call(String fn, List<Object> args) =>
      throw UnsupportedError('core not available');

  Future<dynamic> callAsync(String fn, List<Object> args) async =>
      throw UnsupportedError('core not available');

  Future<void> openFile(String path) async {}

  String tempPath(String name) => name;

  String get deviceName => 'web';
}
