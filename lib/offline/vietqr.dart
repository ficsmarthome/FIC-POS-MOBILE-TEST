class VietQrPayload {
  static String _tlv(String id, String value) => '$id${value.length.toString().padLeft(2, '0')}$value';

  static int _crc16(String input) {
    var crc = 0xFFFF;
    for (final c in input.codeUnits) {
      crc ^= (c << 8);
      for (var i = 0; i < 8; i++) {
        crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
      }
    }
    return crc & 0xFFFF;
  }

  static String build({required String acqId, required String accountNo, required num amount, String addInfo = ''}) {
    final beneficiary = _tlv('00', acqId) + _tlv('01', accountNo);
    final merchantAccount = _tlv('00', 'A000000727') + _tlv('01', beneficiary) + _tlv('02', 'QRIBFTTA');
    var payload = _tlv('00', '01') + _tlv('01', '12') + _tlv('38', merchantAccount) + _tlv('53', '704');
    if (amount > 0) {
      final amountText = amount % 1 == 0 ? amount.toInt().toString() : amount.toStringAsFixed(2);
      payload += _tlv('54', amountText);
    }
    payload += _tlv('58', 'VN');
    final cleanInfo = addInfo.trim();
    if (cleanInfo.isNotEmpty) payload += _tlv('62', _tlv('08', cleanInfo.length > 25 ? cleanInfo.substring(0, 25) : cleanInfo));
    payload += '6304';
    final crc = _crc16(payload).toRadixString(16).toUpperCase().padLeft(4, '0');
    return '$payload$crc';
  }
}
