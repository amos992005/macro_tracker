import 'file_platform_stub.dart'
    if (dart.library.io) 'file_platform_io.dart'
    if (dart.library.html) 'file_platform_web.dart' as platform;

Future<String> readTextFromPath(String path) => platform.readTextFromPath(path);
Future<void> writeTextToPath(String path, String contents) => platform.writeTextToPath(path, contents);
