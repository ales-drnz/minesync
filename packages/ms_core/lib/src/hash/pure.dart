// Fallback in puro Dart: package:crypto (BSD-3).
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'backend.dart';

class CryptoBackend implements Sha256Backend {
  CryptoBackend(this.detail);
  @override
  final String detail;
  @override
  String get name => 'crypto';
  @override
  bool get isNative => false;
  @override
  Sha256Ctx newCtx() => _CryptoCtx();
}

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}

class _CryptoCtx implements Sha256Ctx {
  @override
  final Uint8List buffer = Uint8List(stageSize);
  @override
  void updateBuffer(int n) => update(buffer, 0, n);

  @override
  void updateFrom(Sha256Ctx src, int start, int n) => update(src.buffer, start, start + n);

  late _DigestSink _out;
  late ByteConversionSink _in;
  _CryptoCtx() {
    _reset();
  }
  void _reset() {
    _out = _DigestSink();
    _in = crypto.sha256.startChunkedConversion(_out);
  }

  @override
  void update(Uint8List data, [int start = 0, int? end]) =>
      _in.addSlice(data, start, end ?? data.length, false);

  @override
  Uint8List finish() {
    _in.close();
    final out = Uint8List.fromList(_out.value!.bytes);
    _reset();
    return out;
  }

  @override
  void dispose() {}
}
