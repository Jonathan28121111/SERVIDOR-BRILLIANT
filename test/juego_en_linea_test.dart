import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:servidor_brilliant/almacen_usuarios.dart';
import 'package:servidor_brilliant/api.dart';
import 'package:servidor_brilliant/sesiones.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

/// Un jugador conectado al servidor de verdad.
class Cliente {
  final IOWebSocketChannel canal;
  final StreamQueue<Map<String, Object?>> _cola;

  Cliente._(this.canal, this._cola);

  static Future<Cliente> abrir(int puerto) async {
    final canal = IOWebSocketChannel.connect('ws://localhost:$puerto/juego');
    await canal.ready;
    final cola = StreamQueue(
      canal.stream.map((d) => jsonDecode(d as String) as Map<String, Object?>),
    );
    return Cliente._(canal, cola);
  }

  void mandar(Map<String, Object?> mensaje) =>
      canal.sink.add(jsonEncode(mensaje));

  /// Espera el siguiente mensaje de ese tipo, saltándose los demás.
  Future<Map<String, Object?>> esperar(String tipo) async {
    while (true) {
      final m = await _cola.next.timeout(const Duration(seconds: 5));
      if (m['tipo'] == tipo) return m;
    }
  }

  Future<bool> seCerro() async {
    try {
      while (true) {
        await _cola.next.timeout(const Duration(seconds: 5));
      }
    } on StateError {
      return true;
    }
  }

  Future<void> cerrar() => canal.sink.close();
}

/// Cola mínima sobre un stream, para leer mensajes uno a uno.
class StreamQueue<T> {
  final List<T> _listos = [];
  final List<Completer<T>> _esperando = [];
  bool _terminado = false;

  StreamQueue(Stream<T> stream) {
    stream.listen(
      (dato) {
        if (_esperando.isNotEmpty) {
          _esperando.removeAt(0).complete(dato);
        } else {
          _listos.add(dato);
        }
      },
      onDone: () {
        _terminado = true;
        for (final c in _esperando) {
          c.completeError(StateError('cerrado'));
        }
        _esperando.clear();
      },
    );
  }

  Future<T> get next {
    if (_listos.isNotEmpty) return Future.value(_listos.removeAt(0));
    if (_terminado) return Future.error(StateError('cerrado'));
    final c = Completer<T>();
    _esperando.add(c);
    return c.future;
  }
}

void main() {
  late HttpServer servidor;
  late Sesiones sesiones;
  late int puerto;

  setUp(() async {
    sesiones = Sesiones();
    final api = Api(
      almacen: AlmacenUsuarios.enMemoria(),
      sesiones: sesiones,
      intervaloPing: null,
    );
    servidor = await io.serve(api.manejador, InternetAddress.loopbackIPv4, 0);
    puerto = servidor.port;
  });

  tearDown(() => servidor.close(force: true));

  Future<Cliente> entrar(String usuario) async {
    final cliente = await Cliente.abrir(puerto);
    cliente.mandar({'tipo': 'hola', 'token': sesiones.abrir(usuario)});
    await cliente.esperar('bienvenida');
    return cliente;
  }

  test('sin un token valido el servidor cuelga', () async {
    final cliente = await Cliente.abrir(puerto);
    cliente.mandar({'tipo': 'hola', 'token': 'inventado'});

    final error = await cliente.esperar('error');
    expect(error['error'], 'sin_sesion');
    expect(await cliente.seCerro(), isTrue);
  });

  test('un mensaje que no es JSON no tumba la conexion', () async {
    final ana = await entrar('ana');
    ana.canal.sink.add('{esto no es json');

    expect((await ana.esperar('error'))['error'], 'mensaje_invalido');

    ana.mandar({'tipo': 'crear_sala', 'nivel': 1});
    expect((await ana.esperar('estado'))['fase'], 'espera');
    await ana.cerrar();
  });

  test('partida completa: lobby, codigo, anclas, ronda y rendicion', () async {
    final ana = await entrar('ana');
    final beto = await entrar('beto');

    ana.mandar({'tipo': 'crear_sala', 'nivel': 1});
    final codigo = (await ana.esperar('estado'))['codigo'];

    beto.mandar({'tipo': 'unirse', 'codigo': codigo});
    final sala = await beto.esperar('estado');
    expect((sala['jugadores'] as List).length, 2);

    ana.mandar({'tipo': 'empezar'});
    expect((await beto.esperar('estado'))['fase'], 'anclas');

    ana.mandar({
      'tipo': 'anclas',
      'valores': [
        [0, 0, 1],
      ],
    });
    beto.mandar({
      'tipo': 'anclas',
      'valores': [
        [0, 0, 2],
      ],
    });
    Map<String, Object?> estado;
    do {
      estado = await beto.esperar('estado');
    } while (estado['fase'] != 'juego');
    expect(estado['ronda'], 1);
    expect(estado['dados'], hasLength(2));

    beto.mandar({'tipo': 'rendirse'});
    do {
      estado = await ana.esperar('estado');
    } while (estado['fase'] != 'terminada');
    expect(estado['resultado'], {'ganador': 'ana', 'motivo': 'rendicion'});

    await ana.cerrar();
    await beto.cerrar();
  });

  test('cerrar el socket a media partida deja al jugador desconectado',
      () async {
    final ana = await entrar('ana');
    final beto = await entrar('beto');
    ana.mandar({'tipo': 'crear_sala', 'nivel': 1});
    final codigo = (await ana.esperar('estado'))['codigo'];
    beto.mandar({'tipo': 'unirse', 'codigo': codigo});
    await ana.esperar('estado');
    ana.mandar({'tipo': 'empezar'});
    await ana.esperar('estado');

    await beto.cerrar();

    Map<String, Object?> estado;
    do {
      estado = await ana.esperar('estado');
    } while ((estado['jugadores'] as List)
        .cast<Map<String, Object?>>()
        .any((j) => j['conectado'] == true && j['usuario'] == 'beto'));
    final caido = (estado['jugadores'] as List)
        .cast<Map<String, Object?>>()
        .firstWhere((j) => j['usuario'] == 'beto');
    expect(caido['segundosGracia'], greaterThan(0));

    final vuelve = await entrar('beto');
    final recuperado = await vuelve.esperar('estado');
    expect(recuperado['fase'], 'anclas');
    expect(recuperado['codigo'], codigo);

    await ana.cerrar();
    await vuelve.cerrar();
  });
}
