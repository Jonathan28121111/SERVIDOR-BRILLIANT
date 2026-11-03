import 'package:servidor_brilliant/contrasenas.dart';
import 'package:test/test.dart';

void main() {
  group('cifrar', () {
    test('nunca guarda la contrasena en claro', () {
      final guardado = Contrasenas.cifrar('caballo-correcto-grapa');

      expect(guardado, isNot(contains('caballo')));
      expect(guardado, isNot(contains('correcto')));
      expect(guardado, isNot(contains('grapa')));
    });

    test('guarda el algoritmo y las vueltas para poder subirlas despues', () {
      final partes = Contrasenas.cifrar('contrasena123').split(r'$');

      expect(partes, hasLength(4));
      expect(partes[0], 'pbkdf2-sha256');
      expect(int.parse(partes[1]), Contrasenas.iteraciones);
    });

    test('la misma contrasena dos veces da resultados distintos', () {
      final uno = Contrasenas.cifrar('contrasena123');
      final otro = Contrasenas.cifrar('contrasena123');

      expect(uno, isNot(otro));
    });

    test('las dos versiones siguen validando', () {
      final uno = Contrasenas.cifrar('contrasena123');
      final otro = Contrasenas.cifrar('contrasena123');

      expect(Contrasenas.verificar('contrasena123', uno), isTrue);
      expect(Contrasenas.verificar('contrasena123', otro), isTrue);
    });
  });

  group('verificar', () {
    test('acepta la contrasena correcta', () {
      final guardado = Contrasenas.cifrar('mi-contrasena-larga');

      expect(Contrasenas.verificar('mi-contrasena-larga', guardado), isTrue);
    });

    test('rechaza una contrasena distinta', () {
      final guardado = Contrasenas.cifrar('mi-contrasena-larga');

      expect(Contrasenas.verificar('mi-contrasena-larg', guardado), isFalse);
      expect(Contrasenas.verificar('Mi-Contrasena-Larga', guardado), isFalse);
      expect(Contrasenas.verificar('', guardado), isFalse);
    });

    test('rechaza un formato que no reconoce sin reventar', () {
      for (final basura in [
        '',
        'nada',
        r'md5$1$sal$clave',
        r'pbkdf2-sha256$sal$clave',
        r'pbkdf2-sha256$abc$sal$clave',
        r'pbkdf2-sha256$1000$no-es-base64!$tampoco!',
      ]) {
        expect(Contrasenas.verificar('lo-que-sea', basura), isFalse,
            reason: 'no debio aceptar: $basura');
      }
    });

    test('distingue contrasenas que solo cambian en el ultimo caracter', () {
      final guardado = Contrasenas.cifrar('contrasena1');

      expect(Contrasenas.verificar('contrasena2', guardado), isFalse);
    });
  });

  group('el costo esta puesto a proposito', () {
    test('usa al menos cien mil vueltas', () {
      expect(Contrasenas.iteraciones, greaterThanOrEqualTo(100000));
    });

    test('cifrar tarda algo medible', () {
      final reloj = Stopwatch()..start();
      Contrasenas.cifrar('contrasena123');
      reloj.stop();

      expect(reloj.elapsedMilliseconds, greaterThan(5));
    });
  });
}
