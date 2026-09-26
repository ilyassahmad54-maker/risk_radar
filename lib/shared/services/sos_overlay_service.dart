import 'package:flutter/material.dart';

import '../navigation/app_navigator.dart';
import '../screens/sos_acknowledge_screen.dart';

class SosOverlayService {
  const SosOverlayService._();

  static bool _isShowing = false;

  static Future<void> showFromPayload(Map<String, dynamic> payload) async {
    if (_isShowing) {
      return;
    }

    _isShowing = true;

    final navigator = await _waitForNavigator();
    if (navigator == null) {
      debugPrint('SOS overlay skipped: navigator not ready.');
      _isShowing = false;
      return;
    }

    try {
      await navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => SosAcknowledgeScreen(payload: payload),
          fullscreenDialog: true,
        ),
      );
    } catch (e, stackTrace) {
      debugPrint('SOS acknowledge navigation error: $e');
      debugPrint(stackTrace.toString());
    } finally {
      _isShowing = false;
    }
  }

  static Future<NavigatorState?> _waitForNavigator() async {
    for (var i = 0; i < 12; i++) {
      final navigator = navigatorKey.currentState;

      if (navigator != null) {
        return navigator;
      }

      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    return null;
  }
}
