import 'dart:io';

Future<String> readTextFromPath(String path) => File(path).readAsString();
Future<void> writeTextToPath(String path, String contents) => File(path).writeAsString(contents);
