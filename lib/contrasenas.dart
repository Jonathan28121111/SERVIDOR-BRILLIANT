import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class Contrasenas {
  Contrasenas._();

  static const String _etiqueta = 'pbkdf2-sha256';
  static const int iteraciones = 120000;
  static const int _largoSal = 16;
  static const int _largoClave = 32;

  static final Random _azar = Random.secure();

  static String cifrar(String contrasena) {
    final sal = _salAleatoria();
    final clave = _pbkdf2(
      utf8.encode(contrasena),
      sal,
      iteraciones,
      _largoClave,
    );
    return [
      _etiqueta,
      '$iteraciones',
      base64.encode(sal),
      base64.encode(clave),
    ].join(r'$');
  }

  static bool verificar(String contrasena, String guardado) {
    final partes = guardado.split(r'$');
    if (partes.length != 4 || partes[0] != _etiqueta) {
      return false;
    }
    final vueltas = int.tryParse(partes[1]);
    if (vueltas == null || vueltas < 1) {
      return false;
    }

    final List<int> sal;
    final List<int> esperado;
    try {
      sal = base64.decode(partes[2]);
      esperado = base64.decode(partes[3]);
    } on FormatException {
      return false;
    }

    final calculado = _pbkdf2(
      utf8.encode(contrasena),
      sal,
      vueltas,
      esperado.length,
    );
    return _igualesEnTiempoConstante(calculado, esperado);
  }

  static Uint8List _salAleatoria() {
    return Uint8List.fromList(
      List<int>.generate(_largoSal, (_) => _azar.nextInt(256)),
    );
  }

  static bool _igualesEnTiempoConstante(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    var diferencia = 0;
    for (var i = 0; i < a.length; i++) {
      diferencia |= a[i] ^ b[i];
    }
    return diferencia == 0;
  }

  static Uint8List _pbkdf2(
    List<int> contrasena,
    List<int> sal,
    int vueltas,
    int largo,
  ) {
    final hmac = Hmac(sha256, contrasena);
    final salida = BytesBuilder();

    var bloque = 1;
    while (salida.length < largo) {
      final entrada = <int>[
        ...sal,
        (bloque >> 24) & 0xff,
        (bloque >> 16) & 0xff,
        (bloque >> 8) & 0xff,
        bloque & 0xff,
      ];
      var u = Uint8List.fromList(hmac.convert(entrada).bytes);
      final acumulado = Uint8List.fromList(u);

      for (var vuelta = 1; vuelta < vueltas; vuelta++) {
        u = Uint8List.fromList(hmac.convert(u).bytes);
        for (var i = 0; i < acumulado.length; i++) {
          acumulado[i] ^= u[i];
        }
      }

      salida.add(acumulado);
      bloque++;
    }

    return Uint8List.fromList(salida.toBytes().sublist(0, largo));
  }
}
