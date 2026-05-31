import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

class CloudinaryService {
  static const _cloudName = 'dfqmrvc0a';
  static const _apiKey = '456771521135528';
  static const _apiSecret = 'p_RJH7zqPwzm_biPleZuAQ8RfMU';

  final _dio = Dio();

  Future<String> uploadImage(
    File file, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final timestamp =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final signature = _sign({'timestamp': timestamp});

    final formData = FormData.fromMap({
      'file': await MultipartFile.fromFile(file.path),
      'api_key': _apiKey,
      'timestamp': timestamp,
      'signature': signature,
    });

    final response = await _dio.post<Map<String, dynamic>>(
      'https://api.cloudinary.com/v1_1/$_cloudName/image/upload',
      data: formData,
      onSendProgress: onProgress,
    );

    final url = response.data?['secure_url'];
    if (url == null) throw Exception('Upload failed: ${response.data}');
    return url as String;
  }

  String _sign(Map<String, String> params) {
    final paramString = (params.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key)))
        .map((e) => '${e.key}=${e.value}')
        .join('&');
    return sha1.convert(utf8.encode('$paramString$_apiSecret')).toString();
  }
}
