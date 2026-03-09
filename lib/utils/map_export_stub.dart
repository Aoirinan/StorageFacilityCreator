// Stub for non-web: never called when kIsWeb is true.
import 'dart:typed_data';

void downloadBytesAsFileWeb(Uint8List bytes, String filename) {
  throw UnsupportedError('Web download is only supported on web');
}
