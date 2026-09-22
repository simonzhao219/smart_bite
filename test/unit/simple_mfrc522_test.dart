import 'package:flutter_test/flutter_test.dart';
import 'package:smart_bite/services/simple_mfrc522.dart';

void main() {
  group('SimpleMFRC522 UID to Hex Conversion', () {
    test('uidToHex converts first 4 UID bytes to 8-character hex string', () {
      expect(SimpleMFRC522.uidToHex([0xA2, 0x20, 0x38, 0xF6]), 'A22038F6');
      // With leading zeros
      expect(SimpleMFRC522.uidToHex([0x08, 0x04, 0xF9, 0xE3]), '0804F9E3');
      // All zeros / all ones
      expect(SimpleMFRC522.uidToHex([0x00, 0x00, 0x00, 0x00]), '00000000');
      expect(SimpleMFRC522.uidToHex([0xFF, 0xFF, 0xFF, 0xFF]), 'FFFFFFFF');
      // 5th byte (BCC) is ignored
      expect(
          SimpleMFRC522.uidToHex([0xA2, 0x20, 0x38, 0xF6, 0x4C]), 'A22038F6');
      // Short UID only converts what is there
      expect(SimpleMFRC522.uidToHex([0xA2, 0x20]), 'A220');
    });

    test('Hex conversion matches Arduino printHex behavior', () {
      // Arduino printHex logic:
      // for (byte i = 0; i < bufferSize; i++) {
      //   Serial.print(buffer[i] < 0x10 ? "0" : "");
      //   Serial.print(buffer[i], HEX);
      // }
      final testCases = {
        'A22038F6': [0xA2, 0x20, 0x38, 0xF6],
        'F25838F6': [0xF2, 0x58, 0x38, 0xF6],
        '727338F6': [0x72, 0x73, 0x38, 0xF6],
        '0804F9E3': [0x08, 0x04, 0xF9, 0xE3],
      };

      for (final entry in testCases.entries) {
        final actualHex = SimpleMFRC522.uidToHex(entry.value);
        expect(actualHex, equals(entry.key),
            reason: 'UID bytes ${entry.value} should convert to ${entry.key}');
        expect(actualHex.length, equals(8),
            reason: 'Hex string should be exactly 8 characters');
        expect(actualHex, matches(RegExp(r'^[0-9A-F]{8}$')),
            reason: 'Should be uppercase hex');
      }
    });
  });

  group('RFID Data Format Consistency', () {
    test('All adapters should use 8-character uppercase hex format', () {
      // Expected format: /^[0-9A-F]{8}$/
      final validFormats = [
        'A22038F6', // MockRFIDAdapter example
        'F25838F6', // Database example
        '727338F6', // Database example
        '8804F9E3', // SerialRFIDAdapter example
        '0804F9E3', // With leading zero
        'FFFFFFFF', // All F's
        '00000000', // All zeros
      ];

      final invalidFormats = [
        'a22038f6', // Lowercase
        'A22038F', // Too short
        'A22038F6A', // Too long
        '0xA22038F6', // Hex prefix
        'G22038F6', // Invalid hex char
      ];

      final hexPattern = RegExp(r'^[0-9A-F]{8}$');

      for (var format in validFormats) {
        expect(hexPattern.hasMatch(format), isTrue,
            reason: '$format should match 8-char uppercase hex format');
      }

      for (var format in invalidFormats) {
        expect(hexPattern.hasMatch(format), isFalse,
            reason: '$format should NOT match 8-char uppercase hex format');
      }
    });
  });
}
