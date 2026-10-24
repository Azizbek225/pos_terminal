import 'dart:js_interop';

@JS('POS_CONFIG')
external _PosConfig? get _posConfig;

extension type _PosConfig._(JSObject _) implements JSObject {
  external String? get url;
  external String? get key;
}

/// (server manzili, API kalit) — PosServer sahifaga qo'yadi; bo'lmasa null.
(String, String)? webServerConfig() {
  final c = _posConfig;
  final url = c?.url, key = c?.key;
  if (url == null || url.isEmpty || key == null || key.isEmpty) return null;
  return (url, key);
}
