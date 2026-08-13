import 'package:flutter/services.dart';

class ICloudBackupService {
  const ICloudBackupService();

  static const _channel = MethodChannel('edui/icloud_backup');

  Future<bool> export(String contents, String filename) async =>
      await _channel.invokeMethod<bool>('export', {
        'contents': contents,
        'filename': filename,
      }) ??
      false;

  Future<String?> import() => _channel.invokeMethod<String>('import');
}
