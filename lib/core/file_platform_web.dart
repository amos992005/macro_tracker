Future<String> readTextFromPath(String path) => Future.error(UnsupportedError('Use the selected file bytes in a browser.'));
Future<void> writeTextToPath(String path, String contents) async {
  throw UnsupportedError('Browser downloads are handled by file_picker.');
}
