import 'dart:convert';

import 'package:servidor_brilliant/almacen_usuarios.dart';
import 'package:servidor_brilliant/api.dart';
import 'package:servidor_brilliant/sesiones.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late Api api;
  late Handler manejador;

  setUp(() {
    api = Api(almacen: AlmacenUsuarios.enMemoria());
    manejador = api.manejador;
  });

  Future<Response> pedir(
    String metodo,
    String ruta, {
    Map<String, dynamic>? cuerpo,
    String? token,
  }) async {
    return await manejador(Request(
      metodo,
      Uri.parse('http://localhost$ruta'),
      body: cuerpo == null ? null : jsonEncode(cuerpo),
      headers: {
        'content-type': 'application/json',
        if (token != null) 'authorization': 'Bearer $token',
      },
    ));
  }

  Future<Map<String, dynamic>> json(Response r) async =>
      jsonDecode(await r.readAsString()) as Map<String, dynamic>;

  Future<String> cuentaNueva([String nombre = 'jonathan']) async {
    final r = await pedir('POST', '/registro',
        cuerpo: {'usuario': nombre, 'contrasena': 'contrasena123'});
    return (await json(r))['token'] as String;
  }

  group('POST /registro', () {
    test('crea la cuenta y devuelve un token', () async {
      final r = await pedir('POST', '/registro',
          cuerpo: {'usuario': 'jonathan', 'contrasena': 'contrasena123'});

      expect(r.statusCode, 201);
      final cuerpo = await json(r);
      expect(cuerpo['usuario'], 'jonathan');
      expect(cuerpo['token'], isA<String>());
      expect((cuerpo['token'] as String).length, greaterThan(20));
    });

    test('nunca devuelve la contrasena', () async {
      final r = await pedir('POST', '/registro',
          cuerpo: {'usuario': 'jonathan', 'contrasena': 'contrasena123'});

      expect(await r.readAsString(), isNot(contains('contrasena123')));
    });

    test('rechaza un nombre ocupado con 409', () async {
      await cuentaNueva();

      final r = await pedir('POST', '/registro',
          cuerpo: {'usuario': 'jonathan', 'contrasena': 'otra-contrasena'});

      expect(r.statusCode, 409);
      expect((await json(r))['error'], 'nombre_ocupado');
    });

    test('rechaza una contrasena corta con 400', () async {
      final r = await pedir('POST', '/registro',
          cuerpo: {'usuario': 'jonathan', 'contrasena': 'corta'});

      expect(r.statusCode, 400);
      expect((await json(r))['error'], 'contrasena_corta');
    });

    test('rechaza un cuerpo sin los campos', () async {
      final r = await pedir('POST', '/registro', cuerpo: {'usuario': 'solo'});

      expect(r.statusCode, 400);
      expect((await json(r))['error'], 'faltan_campos');
    });
  });

  group('POST /sesion', () {
    setUp(() async => cuentaNueva());

    test('entra con las credenciales correctas', () async {
      final r = await pedir('POST', '/sesion',
          cuerpo: {'usuario': 'jonathan', 'contrasena': 'contrasena123'});

      expect(r.statusCode, 200);
      expect((await json(r))['token'], isA<String>());
    });

    test('cada inicio de sesion da un token distinto', () async {
      final uno = await cuentaNueva('otro');
      final dos = await pedir('POST', '/sesion',
          cuerpo: {'usuario': 'otro', 'contrasena': 'contrasena123'});

      expect((await json(dos))['token'], isNot(uno));
    });

    test('rechaza la contrasena equivocada con 401', () async {
      final r = await pedir('POST', '/sesion',
          cuerpo: {'usuario': 'jonathan', 'contrasena': 'equivocada'});

      expect(r.statusCode, 401);
      expect((await json(r))['error'], 'credenciales_malas');
    });

    test('contesta igual si el usuario no existe', () async {
      final existente = await pedir('POST', '/sesion',
          cuerpo: {'usuario': 'jonathan', 'contrasena': 'equivocada'});
      final inexistente = await pedir('POST', '/sesion',
          cuerpo: {'usuario': 'nadie', 'contrasena': 'equivocada'});

      expect(inexistente.statusCode, existente.statusCode);
      expect(await json(inexistente), await json(existente));
    });

    test('bloquea despues de varios intentos fallidos', () async {
      for (var i = 0; i < 5; i++) {
        await pedir('POST', '/sesion',
            cuerpo: {'usuario': 'jonathan', 'contrasena': 'equivocada'});
      }

      final r = await pedir('POST', '/sesion',
          cuerpo: {'usuario': 'jonathan', 'contrasena': 'contrasena123'});

      expect(r.statusCode, 429);
      expect((await json(r))['error'], 'demasiados_intentos');
    });
  });

  group('GET /yo', () {
    test('devuelve la cuenta con un token valido', () async {
      final token = await cuentaNueva();

      final r = await pedir('GET', '/yo', token: token);

      expect(r.statusCode, 200);
      expect((await json(r))['usuario'], 'jonathan');
    });

    test('rechaza sin token', () async {
      expect((await pedir('GET', '/yo')).statusCode, 401);
    });

    test('rechaza un token inventado', () async {
      expect((await pedir('GET', '/yo', token: 'inventado')).statusCode, 401);
    });
  });

  group('DELETE /sesion', () {
    test('cierra la sesion y el token deja de servir', () async {
      final token = await cuentaNueva();

      final salida = await pedir('DELETE', '/sesion', token: token);

      expect(salida.statusCode, 204);
      expect((await pedir('GET', '/yo', token: token)).statusCode, 401);
    });

    test('la cuenta sigue existiendo', () async {
      final token = await cuentaNueva();
      await pedir('DELETE', '/sesion', token: token);

      final otra = await pedir('POST', '/sesion',
          cuerpo: {'usuario': 'jonathan', 'contrasena': 'contrasena123'});

      expect(otra.statusCode, 200);
    });
  });

  group('DELETE /cuenta', () {
    test('borra la cuenta cuando se confirma la contrasena', () async {
      final token = await cuentaNueva();

      final r = await pedir('DELETE', '/cuenta',
          cuerpo: {'contrasena': 'contrasena123'}, token: token);

      expect(r.statusCode, 204);
      expect(api.almacen.existe('jonathan'), isFalse);
    });

    test('no borra sin la contrasena', () async {
      final token = await cuentaNueva();

      final r = await pedir('DELETE', '/cuenta', token: token);

      expect(r.statusCode, 400);
      expect(api.almacen.existe('jonathan'), isTrue);
    });

    test('no borra con la contrasena equivocada', () async {
      final token = await cuentaNueva();

      final r = await pedir('DELETE', '/cuenta',
          cuerpo: {'contrasena': 'equivocada'}, token: token);

      expect(r.statusCode, 403);
      expect(api.almacen.existe('jonathan'), isTrue);
    });

    test('no borra sin sesion', () async {
      await cuentaNueva();

      final r = await pedir('DELETE', '/cuenta',
          cuerpo: {'contrasena': 'contrasena123'});

      expect(r.statusCode, 401);
      expect(api.almacen.existe('jonathan'), isTrue);
    });

    test('al borrar se cierran todas las sesiones de esa cuenta', () async {
      final primera = await cuentaNueva();
      final respuesta = await pedir('POST', '/sesion',
          cuerpo: {'usuario': 'jonathan', 'contrasena': 'contrasena123'});
      final segunda = (await json(respuesta))['token'] as String;

      await pedir('DELETE', '/cuenta',
          cuerpo: {'contrasena': 'contrasena123'}, token: primera);

      expect((await pedir('GET', '/yo', token: primera)).statusCode, 401);
      expect((await pedir('GET', '/yo', token: segunda)).statusCode, 401);
    });

    test('el nombre queda libre para registrarse otra vez', () async {
      final token = await cuentaNueva();
      await pedir('DELETE', '/cuenta',
          cuerpo: {'contrasena': 'contrasena123'}, token: token);

      final r = await pedir('POST', '/registro',
          cuerpo: {'usuario': 'jonathan', 'contrasena': 'otra-contrasena'});

      expect(r.statusCode, 201);
    });
  });

  group('las sesiones', () {
    test('caducan', () {
      final sesiones = Sesiones(duracion: Duration.zero);
      final token = sesiones.abrir('jonathan');

      expect(sesiones.usuarioDe(token), isNull);
    });

    test('un token sirve mientras no caduque', () {
      final sesiones = Sesiones(duracion: const Duration(days: 1));
      final token = sesiones.abrir('jonathan');

      expect(sesiones.usuarioDe(token), 'jonathan');
    });

    test('cerrar una no tumba las demas', () {
      final sesiones = Sesiones();
      final uno = sesiones.abrir('jonathan');
      final dos = sesiones.abrir('jonathan');

      sesiones.cerrar(uno);

      expect(sesiones.usuarioDe(uno), isNull);
      expect(sesiones.usuarioDe(dos), 'jonathan');
    });
  });

  group('GET /salud', () {
    test('contesta para saber si el servidor esta arriba', () async {
      final r = await pedir('GET', '/salud');

      expect(r.statusCode, 200);
      expect((await json(r))['estado'], 'bien');
    });
  });

  group('CORS', () {
    test('contesta la peticion previa del navegador', () async {
      final r = await pedir('OPTIONS', '/registro');

      expect(r.statusCode, 204);
      expect(r.headers['access-control-allow-origin'], '*');
      expect(
          r.headers['access-control-allow-headers'], contains('authorization'));
    });

    test('pone las cabeceras en las respuestas normales', () async {
      final r = await pedir('GET', '/salud');

      expect(r.headers['access-control-allow-origin'], '*');
    });
  });
}
