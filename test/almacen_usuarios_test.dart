import 'dart:io';

import 'package:servidor_brilliant/almacen_usuarios.dart';
import 'package:test/test.dart';

void main() {
  late AlmacenUsuarios almacen;

  setUp(() => almacen = AlmacenUsuarios.enMemoria());

  group('registrar', () {
    test('crea la cuenta y la deja encontrable', () {
      final resultado = almacen.registrar('jonathan', 'contrasena123');

      expect(resultado.salioBien, isTrue);
      expect(resultado.usuario!.nombre, 'jonathan');
      expect(almacen.existe('jonathan'), isTrue);
      expect(almacen.cuantos, 1);
    });

    test('no guarda la contrasena en claro', () {
      almacen.registrar('jonathan', 'contrasena123');

      final guardada = almacen.buscar('jonathan')!.contrasenaCifrada;
      expect(guardada, isNot(contains('contrasena123')));
    });

    test('rechaza un nombre ya ocupado', () {
      almacen.registrar('jonathan', 'contrasena123');

      final otro = almacen.registrar('jonathan', 'otra-contrasena');

      expect(otro.salioBien, isFalse);
      expect(otro.fallo, FalloCuenta.nombreOcupado);
      expect(almacen.cuantos, 1);
    });

    test('no deja colar el mismo nombre con otras mayusculas', () {
      almacen.registrar('jonathan', 'contrasena123');

      final otro = almacen.registrar('JONATHAN', 'contrasena123');

      expect(otro.fallo, FalloCuenta.nombreOcupado);
    });

    test('rechaza contrasenas cortas', () {
      final resultado = almacen.registrar('jonathan', 'corta');

      expect(resultado.fallo, FalloCuenta.contrasenaCorta);
      expect(almacen.cuantos, 0);
    });

    test('rechaza nombres invalidos', () {
      for (final malo in ['', 'ab', 'con espacio', 'simbolo!', 'a' * 21]) {
        final resultado = almacen.registrar(malo, 'contrasena123');
        expect(resultado.fallo, FalloCuenta.nombreInvalido,
            reason: 'acepto el nombre "$malo"');
      }
    });

    test('le quita los espacios de los lados al nombre', () {
      almacen.registrar('  jonathan  ', 'contrasena123');

      expect(almacen.buscar('jonathan')!.nombre, 'jonathan');
    });
  });

  group('autenticar', () {
    setUp(() => almacen.registrar('jonathan', 'contrasena123'));

    test('entra con la contrasena correcta', () {
      final resultado = almacen.autenticar('jonathan', 'contrasena123');

      expect(resultado.salioBien, isTrue);
      expect(resultado.usuario!.nombre, 'jonathan');
    });

    test('entra sin importar las mayusculas del nombre', () {
      expect(almacen.autenticar('JONATHAN', 'contrasena123').salioBien, isTrue);
    });

    test('rechaza la contrasena equivocada', () {
      final resultado = almacen.autenticar('jonathan', 'equivocada');

      expect(resultado.fallo, FalloCuenta.credencialesMalas);
    });

    test('da el mismo fallo si el usuario no existe', () {
      final inexistente = almacen.autenticar('nadie', 'contrasena123');
      final malaContrasena = almacen.autenticar('jonathan', 'equivocada');

      expect(inexistente.fallo, FalloCuenta.credencialesMalas);
      expect(malaContrasena.fallo, inexistente.fallo);
    });
  });

  group('borrar', () {
    test('quita la cuenta', () {
      almacen.registrar('jonathan', 'contrasena123');

      expect(almacen.borrar('jonathan'), isTrue);
      expect(almacen.existe('jonathan'), isFalse);
      expect(almacen.cuantos, 0);
    });

    test('avisa si no habia nada que borrar', () {
      expect(almacen.borrar('nadie'), isFalse);
    });

    test('despues de borrar el nombre vuelve a estar libre', () {
      almacen.registrar('jonathan', 'contrasena123');
      almacen.borrar('jonathan');

      expect(
          almacen.registrar('jonathan', 'otra-contrasena').salioBien, isTrue);
    });
  });

  group('en disco', () {
    late Directory carpeta;

    setUp(() => carpeta = Directory.systemTemp.createTempSync('almacen_'));
    tearDown(() => carpeta.deleteSync(recursive: true));

    test('las cuentas sobreviven a un reinicio', () {
      final ruta = '${carpeta.path}/usuarios.json';
      AlmacenUsuarios(ruta).registrar('jonathan', 'contrasena123');

      final otraVez = AlmacenUsuarios(ruta);

      expect(otraVez.existe('jonathan'), isTrue);
      expect(otraVez.autenticar('jonathan', 'contrasena123').salioBien, isTrue);
    });

    test('no deja el archivo temporal tirado', () {
      final ruta = '${carpeta.path}/usuarios.json';
      AlmacenUsuarios(ruta).registrar('jonathan', 'contrasena123');

      expect(File('$ruta.tmp').existsSync(), isFalse);
    });
  });
}
