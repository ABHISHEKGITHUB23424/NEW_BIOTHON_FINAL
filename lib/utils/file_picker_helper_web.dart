import 'dart:async';
import 'dart:html' as html;
import 'file_picker_helper.dart';

Future<PickedFile?> pickFile() async {
  final completer = Completer<PickedFile?>();
  final uploadInput = html.InputElement(type: 'file');
  uploadInput.accept = 'image/*,application/pdf,application/json,text/csv,application/msword,application/vnd.openxmlformats-officedocument.wordprocessingml.document,.csv,.json,.pdf,.doc,.docx';
  uploadInput.click();

  uploadInput.onChange.listen((e) {
    final files = uploadInput.files;
    if (files != null && files.isNotEmpty) {
      final file = files[0];
      final reader = html.FileReader();
      reader.readAsDataUrl(file);
      reader.onLoadEnd.listen((e) {
        final result = reader.result as String;
        // The result format is "data:image/jpeg;base64,..."
        final parts = result.split(',');
        final base64String = parts.length > 1 ? parts[1] : '';
        completer.complete(PickedFile(file.name, base64String));
      });
      reader.onError.listen((err) {
        completer.complete(null);
      });
    } else {
      completer.complete(null);
    }
  });

  return completer.future;
}
