import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'almacen_usuarios.dart';
import 'sesiones.dart';
import 'usuario.dart';

class Api {
  final AlmacenUsuarios almacen;
  final Sesiones sesiones;
  final Freno freno;

  Api({
    required this.almacen,
    Sesiones? sesiones,
    Freno? freno,
  })  : sesiones = sesiones ?? Sesiones(),
        freno = freno ?? Freno();

  Handler get manejador {
    final rutas = Router()
      ..get('/salud', _salud)
      ..post('/registro', _registrar)
      ..post('/sesion', _iniciarSesion)
      ..delete('/sesion', _cerrarSesion)
      ..get('/yo', _yo)
      ..delete('/cuenta', _borrarCuenta);

    return const Pipeline()
        .addMiddleware(_cors)
        .addMiddleware(_sinCache)
        .addMiddleware(logRequests())
        .addHandler(rutas.call);
  }

  Response _salud(Request peticion) => _json(200, {'estado': 'bien'});

  Future<Response> _registrar(Request peticion) async {
    final cuerpo = await _leerJson(peticion);
    if (cuerpo == null) {
      return _error(400, 'cuerpo_invalido', 'Manda un JSON valido.');
    }

    final usuario = cuerpo['usuario'];
    final contrasena = cuerpo['contrasena'];
    if (usuario is! String || contrasena is! String) {
      return _error(400, 'faltan_campos', 'Hacen falta usuario y contrasena.');
    }

    final resultado = almacen.registrar(usuario, contrasena);
    if (!resultado.salioBien) {
      return _deFallo(resultado.fallo!);
    }

    final cuenta = resultado.usuario!;
    return _json(201, {
      'token': sesiones.abrir(cuenta.nombre),
      ...usuarioPublico(cuenta),
    });
  }

  Future<Response> _iniciarSesion(Request peticion) async {
    final cuerpo = await _leerJson(peticion);
    if (cuerpo == null) {
      return _error(400, 'cuerpo_invalido', 'Manda un JSON valido.');
    }

    final usuario = cuerpo['usuario'];
    final contrasena = cuerpo['contrasena'];
    if (usuario is! String || contrasena is! String) {
      return _error(400, 'faltan_campos', 'Hacen falta usuario y contrasena.');
    }

    if (freno.estaBloqueado(usuario)) {
      return _error(
        429,
        'demasiados_intentos',
        'Demasiados intentos fallidos. Espera unos minutos.',
      );
    }

    final resultado = almacen.autenticar(usuario, contrasena);
    if (!resultado.salioBien) {
      freno.anotarFallo(usuario);
      return _deFallo(resultado.fallo!);
    }

    freno.limpiar(usuario);
    final cuenta = resultado.usuario!;
    return _json(200, {
      'token': sesiones.abrir(cuenta.nombre),
      ...usuarioPublico(cuenta),
    });
  }

  Response _cerrarSesion(Request peticion) {
    final token = _token(peticion);
    if (token == null || sesiones.usuarioDe(token) == null) {
      return _error(401, 'sin_sesion', 'No hay sesion abierta.');
    }
    sesiones.cerrar(token);
    return Response(204);
  }

  Response _yo(Request peticion) {
    final nombre = sesiones.usuarioDe(_token(peticion));
    if (nombre == null) {
      return _error(401, 'sin_sesion', 'No hay sesion abierta.');
    }
    final cuenta = almacen.buscar(nombre);
    if (cuenta == null) {
      return _error(401, 'sin_sesion', 'No hay sesion abierta.');
    }
    return _json(200, usuarioPublico(cuenta));
  }

  Future<Response> _borrarCuenta(Request peticion) async {
    final nombre = sesiones.usuarioDe(_token(peticion));
    if (nombre == null) {
      return _error(401, 'sin_sesion', 'No hay sesion abierta.');
    }

    final cuerpo = await _leerJson(peticion);
    final contrasena = cuerpo?['contrasena'];
    if (contrasena is! String) {
      return _error(
        400,
        'falta_contrasena',
        'Confirma tu contrasena para borrar la cuenta.',
      );
    }

    final resultado = almacen.autenticar(nombre, contrasena);
    if (!resultado.salioBien) {
      return _error(403, 'contrasena_mala', 'La contrasena no coincide.');
    }

    almacen.borrar(nombre);
    sesiones.cerrarTodasDe(nombre);
    return Response(204);
  }

  static String? _token(Request peticion) {
    final cabecera = peticion.headers['authorization'];
    if (cabecera == null || !cabecera.toLowerCase().startsWith('bearer ')) {
      return null;
    }
    return cabecera.substring(7).trim();
  }

  static Future<Map<String, dynamic>?> _leerJson(Request peticion) async {
    try {
      final texto = await peticion.readAsString();
      if (texto.isEmpty) {
        return null;
      }
      final decodificado = jsonDecode(texto);
      return decodificado is Map<String, dynamic> ? decodificado : null;
    } on FormatException {
      return null;
    }
  }

  static Response _deFallo(FalloCuenta fallo) {
    switch (fallo) {
      case FalloCuenta.nombreInvalido:
        return _error(
          400,
          'nombre_invalido',
          'El usuario va de ${AlmacenUsuarios.largoMinimoNombre} a '
              '${AlmacenUsuarios.largoMaximoNombre} caracteres, con letras, '
              'numeros, punto, guion o guion bajo.',
        );
      case FalloCuenta.contrasenaCorta:
        return _error(
          400,
          'contrasena_corta',
          'La contrasena necesita al menos '
              '${AlmacenUsuarios.largoMinimoContrasena} caracteres.',
        );
      case FalloCuenta.nombreOcupado:
        return _error(409, 'nombre_ocupado', 'Ese usuario ya existe.');
      case FalloCuenta.credencialesMalas:
        return _error(
          401,
          'credenciales_malas',
          'Usuario o contrasena incorrectos.',
        );
    }
  }

  static Response _json(int codigo, Map<String, dynamic> cuerpo) => Response(
        codigo,
        body: jsonEncode(cuerpo),
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  static Response _error(int codigo, String clave, String mensaje) =>
      _json(codigo, {'error': clave, 'mensaje': mensaje});

  static const _cabecerasCors = {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET, POST, DELETE, OPTIONS',
    'access-control-allow-headers': 'authorization, content-type',
    'access-control-max-age': '86400',
  };

  static Middleware get _cors => (Handler siguiente) {
        return (Request peticion) async {
          if (peticion.method == 'OPTIONS') {
            return Response(204, headers: _cabecerasCors);
          }
          final respuesta = await siguiente(peticion);
          return respuesta.change(headers: _cabecerasCors);
        };
      };

  static Middleware get _sinCache => (Handler siguiente) {
        return (Request peticion) async {
          final respuesta = await siguiente(peticion);
          return respuesta.change(headers: {
            'cache-control': 'no-store',
            'x-content-type-options': 'nosniff',
          });
        };
      };
}
