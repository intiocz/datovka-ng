/// A message meant for the person using the app. Unlike [StateError] it
/// prints without the "Bad state:" prefix.
class UserError implements Exception {
  final String message;

  const UserError(this.message);

  @override
  String toString() => message;
}
