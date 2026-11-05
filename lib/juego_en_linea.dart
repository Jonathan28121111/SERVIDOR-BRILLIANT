import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'salas.dart';
import 'sesiones.dart';

/// La ruta `/juego`: un WebSocket por jugador.
///
/// El primer mensaje tiene que ser `{"tipo": "hola", "token": "..."}`. El
/// token va dentro del mensaje y no en la URL para que no quede en los logs.
class JuegoEnLinea {
  final Sesiones sesiones;
  final GestorSalas salas;

  /// Cuánto se espera el saludo antes de colgar.
  final Duration esperaSaludo;

  /// Cada cuánto se manda un ping; si no hay respuesta, la conexión se da
  /// por muerta y el jugador pasa a desconectado.
  final Duration? intervaloPing;

  static const int largoMaximoMensaje = 4096;

  JuegoEnLinea({
    required this.sesiones,
    required this.salas,
    this.esperaSaludo = const Duration(seconds: 10),
    this.intervaloPing = const Duration(seconds: 10),
  });

  Handler get manejador =>
      webSocketHandler(_alConectar, pingInterval: intervaloPing);

  void _alConectar(WebSocketChannel socket, String? _) {
    final canal = _CanalSocket(socket);
    String? usuario;

    final saludo = Timer(esperaSaludo, () {
      if (usuario == null) {
        canal.error('sin_saludo', 'No llegó el saludo a tiempo.');
        canal.cerrar();
      }
    });

    socket.stream.listen(
      (dato) {
        final mensaje = _leer(dato);
        if (mensaje == null) {
          canal.error('mensaje_invalido', 'El mensaje no es un JSON válido.');
          return;
        }

        final quien = usuario;
        if (quien == null) {
          final nombre = mensaje['tipo'] == 'hola'
              ? sesiones.usuarioDe(mensaje['token'] as String?)
              : null;
          if (nombre == null) {
            canal.error('sin_sesion', 'Inicia sesión para jugar en línea.');
            canal.cerrar();
            return;
          }
          usuario = nombre;
          saludo.cancel();
          salas.conectar(nombre, canal);
          return;
        }

        try {
          salas.recibir(quien, mensaje);
        } catch (error, pila) {
          stderr.writeln('Error atendiendo a $quien: $error\n$pila');
          canal.error('error_interno', 'Algo falló en el servidor.');
        }
      },
      onDone: () {
        saludo.cancel();
        canal.cerrado = true;
        final quien = usuario;
        if (quien != null) {
          salas.desconectar(quien, canal);
        }
      },
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  static Map<String, Object?>? _leer(Object? dato) {
    if (dato is! String || dato.length > largoMaximoMensaje) return null;
    try {
      final json = jsonDecode(dato);
      return json is Map<String, Object?> ? json : null;
    } on FormatException {
      return null;
    }
  }
}

class _CanalSocket implements Canal {
  final WebSocketChannel socket;
  bool cerrado = false;

  _CanalSocket(this.socket);

  @override
  void enviar(Map<String, Object?> mensaje) {
    if (!cerrado) {
      socket.sink.add(jsonEncode(mensaje));
    }
  }

  void error(String clave, String mensaje) =>
      enviar({'tipo': 'error', 'error': clave, 'mensaje': mensaje});

  @override
  void cerrar() {
    if (cerrado) return;
    cerrado = true;
    socket.sink.close();
  }
}
