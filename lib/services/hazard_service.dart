import 'dart:convert';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

class HazardService {
  Future<Map<String, dynamic>> detectHazards(File imageFile) async {
    final bytes = await imageFile.readAsBytes();
    final imageBase64 = base64Encode(bytes);
    final mimeType = _mimeTypeFor(imageFile.path);

    final FunctionResponse response;
    try {
      response = await Supabase.instance.client.functions
          .invoke(
            'analyze-hazard-image',
            body: {'imageBase64': imageBase64, 'mimeType': mimeType},
          )
          .timeout(const Duration(seconds: 90));
    } on FunctionException catch (error) {
      final details = error.details;
      if (details is Map && details['detail'] != null) {
        throw Exception(details['detail']);
      }
      if (details is Map && details['error'] != null) {
        throw Exception(details['error']);
      }
      throw Exception(error.reasonPhrase ?? error.toString());
    }

    final data = response.data;
    if (data is! Map) {
      throw Exception('AI returned an invalid response.');
    }

    final result = Map<String, dynamic>.from(data);
    if (result['error'] != null) {
      throw Exception(result['detail'] ?? result['error']);
    }
    if (result['hazards'] is! List || result['summary'] is! String) {
      throw Exception('AI response is missing required fields.');
    }

    return result;
  }

  String _mimeTypeFor(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }
}
