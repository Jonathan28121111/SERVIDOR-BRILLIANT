import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:servidor_brilliant/salas.dart';
import 'package:test/test.dart';

class CanalFalso implements Canal {
  final List<Map<String, Object?>> recibidos = [];
  bool cerrado = false;

  @override
  void enviar(Map<String, Object?> mensaje) => recibidos.add(mensaje);

  @override
  void cerrar() => cerrado = true;

  Map<String, Object?> get ultimo => recibidos.last;

  Map<String, Object?> get estado =>
      recibidos.lastWhere((m) => m['tipo'] == 'estado');

  Map<String, Object?>? get ultimoError {
    final errores = recibidos.where((m) => m['tipo'] == 'error');
    return errores.isEmpty ? null : errores.last;
  }

  List<Map<String, Object?>> get jugadores =>
      (estado['jugadores'] as List).cast<Map<String, Object?>>();

  Map<String, Object?> jugador(String nombre) =>
      jugadores.firstWhere((j) => j['usuario'] == nombre);
}

/// Dados que siempre salen igual, para saber qué números son válidos.
class AzarFijo implements Random {
  @override
  int nextInt(int max) => 2 % max;

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;
}

const ajustes = Ajustes(
  graciaReconexion: Duration(seconds: 60),
  limiteRonda: Duration(seconds: 90),
  vidaSalaTerminada: Duration(minutes: 10),
  fallosDeCodigoPorMinuto: 3,
);

const anclasAna = [
  [0, 0, 1],
  [0, 6, 2],
];
const anclasBeto = [
  [0, 0, 3],
  [0, 6, 4],
];

void main() {
  late GestorSalas gestor;
  late CanalFalso ana;
  late CanalFalso beto;

  setUp(() {
    gestor = GestorSalas(ajustes: ajustes, azar: AzarFijo());
    ana = CanalFalso();
    beto = CanalFalso();
  });

  void conectarAmbos() {
    gestor.conectar('ana', ana);
    gestor.conectar('beto', beto);
  }

  String crearSala() {
    gestor.recibir('ana', {'tipo': 'crear_sala', 'nivel': 1});
    return ana.estado['codigo'] as String;
  }

  void salaConLosDos() {
    conectarAmbos();
    final codigo = crearSala();
    gestor.recibir('beto', {'tipo': 'unirse', 'codigo': codigo});
  }

  void enJuego() {
    salaConLosDos();
    gestor.recibir('ana', {'tipo': 'empezar'});
    gestor.recibir('ana', {'tipo': 'anclas', 'valores': anclasAna});
    gestor.recibir('beto', {'tipo': 'anclas', 'valores': anclasBeto});
  }

  Map<String, Object?> jugada(
    int ronda, {
    int fila = 1,
    int columna = 1,
    int numero = 3,
    int puntos = 0,
    bool terminado = false,
  }) =>
      {
        'tipo': 'jugada',
        'ronda': ronda,
        'fila': fila,
        'columna': columna,
        'numero': numero,
        'puntos': puntos,
        'terminado': terminado,
      };

  group('conectarse', () {
    test('saluda y avisa que no hay sala', () {
      gestor.conectar('ana', ana);

      expect(ana.recibidos.first, {'tipo': 'bienvenida', 'usuario': 'ana'});
      expect(ana.ultimo['tipo'], 'sin_sala');
    });

    test('una segunda ventana reemplaza a la primera', () {
      final otra = CanalFalso();
      gestor.conectar('ana', ana);
      gestor.conectar('ANA', otra);

      expect(ana.recibidos.map((m) => m['tipo']), contains('reemplazada'));
      expect(ana.cerrado, isTrue);
      expect(otra.cerrado, isFalse);
    });

    test('cerrar la ventana vieja no desconecta a la nueva', () {
      final otra = CanalFalso();
      gestor.conectar('ana', ana);
      gestor.conectar('ana', otra);

      gestor.desconectar('ana', ana);

      expect(gestor.estaConectado('ana'), isTrue);
    });
  });

  group('lobby', () {
    test('crear una sala da un codigo de seis letras faciles de dictar', () {
      gestor.conectar('ana', ana);
      final codigo = crearSala();

      expect(codigo, hasLength(6));
      expect(codigo.split('').every(letrasCodigo.contains), isTrue);
      expect(codigo, isNot(contains('0')));
      expect(codigo, isNot(contains('O')));
      expect(ana.estado['fase'], 'espera');
      expect(ana.estado['anfitrion'], 'ana');
    });

    test('dos salas nunca comparten codigo', () {
      final gestorReal = GestorSalas(ajustes: ajustes);
      final codigos = <String>{};
      for (var i = 0; i < 200; i++) {
        final canal = CanalFalso();
        gestorReal.conectar('u$i', canal);
        gestorReal.recibir('u$i', {'tipo': 'crear_sala', 'nivel': 1});
        codigos.add(canal.estado['codigo'] as String);
      }
      expect(codigos, hasLength(200));
    });

    test('un nivel que no existe se rechaza', () {
      gestor.conectar('ana', ana);
      gestor.recibir('ana', {'tipo': 'crear_sala', 'nivel': 99});

      expect(ana.ultimoError?['error'], 'nivel_invalido');
      expect(gestor.cuantasSalas, 0);
    });

    test('unirse con el codigo pone a los dos en la sala', () {
      salaConLosDos();

      expect(ana.jugadores.map((j) => j['usuario']), ['ana', 'beto']);
      expect(beto.jugadores.map((j) => j['usuario']), ['ana', 'beto']);
    });

    test('el codigo no distingue mayusculas ni espacios', () {
      conectarAmbos();
      final codigo = crearSala();

      gestor.recibir('beto', {
        'tipo': 'unirse',
        'codigo': '  ${codigo.toLowerCase()} ',
      });

      expect(beto.estado['codigo'], codigo);
    });

    test('un codigo que no existe avisa', () {
      gestor.conectar('beto', beto);
      gestor.recibir('beto', {'tipo': 'unirse', 'codigo': 'ZZZZZZ'});

      expect(beto.ultimoError?['error'], 'sala_no_existe');
    });

    test('demasiados codigos equivocados frenan al jugador un minuto', () {
      fakeAsync((tiempo) {
        conectarAmbos();
        final codigo = crearSala();
        for (var i = 0; i < 3; i++) {
          gestor.recibir('beto', {'tipo': 'unirse', 'codigo': 'ZZZZZZ'});
        }

        gestor.recibir('beto', {'tipo': 'unirse', 'codigo': codigo});
        expect(beto.ultimoError?['error'], 'demasiados_intentos');

        tiempo.elapse(const Duration(seconds: 61));
        gestor.recibir('beto', {'tipo': 'unirse', 'codigo': codigo});
        expect(beto.estado['codigo'], codigo);
      });
    });

    test('una sala de dos esta llena para un tercero', () {
      salaConLosDos();
      final caro = CanalFalso();
      gestor.conectar('caro', caro);

      gestor.recibir('caro', {
        'tipo': 'unirse',
        'codigo': ana.estado['codigo'],
      });

      expect(caro.ultimoError?['error'], 'sala_llena');
    });

    test('no se puede estar en dos salas', () {
      conectarAmbos();
      crearSala();

      gestor.recibir('ana', {'tipo': 'crear_sala', 'nivel': 2});

      expect(ana.ultimoError?['error'], 'ya_en_sala');
      expect(gestor.cuantasSalas, 1);
    });

    test('solo el anfitrion empieza y solo con rival', () {
      gestor.conectar('ana', ana);
      crearSala();
      gestor.recibir('ana', {'tipo': 'empezar'});
      expect(ana.ultimoError?['error'], 'falta_rival');

      gestor.conectar('beto', beto);
      gestor.recibir('beto', {
        'tipo': 'unirse',
        'codigo': ana.estado['codigo'],
      });
      gestor.recibir('beto', {'tipo': 'empezar'});
      expect(beto.ultimoError?['error'], 'no_eres_anfitrion');

      gestor.recibir('ana', {'tipo': 'empezar'});
      expect(ana.estado['fase'], 'anclas');
      expect(beto.estado['fase'], 'anclas');
    });

    test('si el invitado se va, el anfitrion sigue esperando', () {
      salaConLosDos();

      gestor.recibir('beto', {'tipo': 'salir_sala'});

      expect(beto.ultimo['tipo'], 'sin_sala');
      expect(ana.jugadores.map((j) => j['usuario']), ['ana']);
    });

    test('si el anfitrion se va, la sala se cierra para el otro', () {
      salaConLosDos();

      gestor.recibir('ana', {'tipo': 'salir_sala'});

      expect(beto.ultimo['tipo'], 'sala_cerrada');
      expect(gestor.cuantasSalas, 0);
    });

    test('si el anfitrion se desconecta en el lobby, la sala se cierra', () {
      salaConLosDos();

      gestor.desconectar('ana', ana);

      expect(beto.ultimo['tipo'], 'sala_cerrada');
      expect(gestor.cuantasSalas, 0);
    });

    test('un mensaje desconocido devuelve un error', () {
      gestor.conectar('ana', ana);
      gestor.recibir('ana', {'tipo': 'hackear'});

      expect(ana.ultimoError?['error'], 'mensaje_desconocido');
    });
  });

  group('anclas', () {
    setUp(() {
      salaConLosDos();
      gestor.recibir('ana', {'tipo': 'empezar'});
    });

    test('el juego empieza cuando los dos mandan sus anclas', () {
      gestor.recibir('ana', {'tipo': 'anclas', 'valores': anclasAna});
      expect(ana.estado['fase'], 'anclas');
      expect(beto.jugador('ana')['listo'], isTrue);

      gestor.recibir('beto', {'tipo': 'anclas', 'valores': anclasBeto});
      expect(ana.estado['fase'], 'juego');
      expect(ana.estado['ronda'], 1);
      expect(ana.estado['dados'], [3, 3]);
      expect(ana.estado['dados'], beto.estado['dados']);
    });

    test('cada quien recibe solo sus casillas', () {
      gestor.recibir('ana', {'tipo': 'anclas', 'valores': anclasAna});

      expect(ana.estado['mias'], anclasAna);
      expect(beto.estado['mias'], isEmpty);
    });

    test('un numero repetido o fuera de rango se rechaza', () {
      gestor.recibir('ana', {
        'tipo': 'anclas',
        'valores': [
          [0, 0, 1],
          [0, 1, 1],
        ],
      });
      expect(ana.ultimoError?['error'], 'anclas_invalidas');

      gestor.recibir('ana', {
        'tipo': 'anclas',
        'valores': [
          [0, 0, 7],
        ],
      });
      expect(ana.ultimoError?['error'], 'anclas_invalidas');

      gestor.recibir('ana', {'tipo': 'anclas', 'valores': 'basura'});
      expect(ana.ultimoError?['error'], 'anclas_invalidas');
    });

    test('no se pueden mandar dos veces', () {
      gestor.recibir('ana', {'tipo': 'anclas', 'valores': anclasAna});
      gestor.recibir('ana', {'tipo': 'anclas', 'valores': anclasAna});

      expect(ana.ultimoError?['error'], 'ya_listo');
    });

    test('salir de la sala a media partida obliga a rendirse', () {
      gestor.recibir('ana', {'tipo': 'salir_sala'});

      expect(ana.ultimoError?['error'], 'partida_en_curso');
    });
  });

  group('rondas', () {
    setUp(enJuego);

    test('la siguiente tirada sale cuando los dos jugaron', () {
      gestor.recibir('ana', jugada(1, puntos: 4));
      expect(ana.estado['ronda'], 1);
      expect(beto.jugador('ana')['jugoRonda'], isTrue);
      expect(beto.jugador('ana')['puntos'], 4);

      gestor.recibir('beto', {'tipo': 'pasar', 'ronda': 1});
      expect(ana.estado['ronda'], 2);
      expect(ana.jugador('ana')['jugoRonda'], isFalse);
    });

    test('la jugada se guarda para poder reconstruir el tablero', () {
      gestor.recibir('ana', jugada(1, fila: 2, columna: 3));

      expect(ana.estado['mias'], [
        ...anclasAna,
        [2, 3, 3]
      ]);
    });

    test('un numero que no salio en los dados se rechaza', () {
      gestor.recibir('ana', jugada(1, numero: 5));

      expect(ana.ultimoError?['error'], 'jugada_invalida');
      expect(beto.jugador('ana')['jugoRonda'], isFalse);
    });

    test('una casilla ocupada se rechaza', () {
      gestor.recibir('ana', jugada(1, fila: 0, columna: 0));

      expect(ana.ultimoError?['error'], 'jugada_invalida');
    });

    test('jugar dos veces la misma ronda se rechaza', () {
      gestor.recibir('ana', jugada(1));
      gestor.recibir('ana', jugada(1, fila: 2));

      expect(ana.ultimoError?['error'], 'ya_jugaste');
    });

    test('una jugada de una ronda vieja se rechaza', () {
      gestor.recibir('ana', jugada(1));
      gestor.recibir('beto', jugada(1));

      gestor.recibir('ana', jugada(1, fila: 3));

      expect(ana.ultimoError?['error'], 'ronda_equivocada');
    });

    test('si se acaba el tiempo, quien no jugo pasa', () {
      fakeAsync((tiempo) {
        gestor = GestorSalas(ajustes: ajustes, azar: AzarFijo());
        enJuego();
        expect(ana.estado['segundosRonda'], 90);

        gestor.recibir('ana', jugada(1));
        tiempo.elapse(const Duration(seconds: 91));

        expect(ana.estado['ronda'], 2);
      });
    });

    test('quien termino su tablero ya no frena las rondas', () {
      gestor.recibir('ana', jugada(1, puntos: 30, terminado: true));
      gestor.recibir('beto', jugada(1, puntos: 10));
      expect(beto.estado['ronda'], 2);

      gestor.recibir('beto', jugada(2, fila: 2, puntos: 12));

      expect(beto.estado['ronda'], 3);
    });
  });

  group('final', () {
    setUp(enJuego);

    test('cuando los dos terminan gana quien tiene mas puntos', () {
      gestor.recibir('ana', jugada(1, puntos: 30, terminado: true));
      gestor.recibir('beto', jugada(1, puntos: 25, terminado: true));

      expect(ana.estado['fase'], 'terminada');
      expect(ana.estado['resultado'], {'ganador': 'ana', 'motivo': 'puntos'});
      expect(beto.estado['resultado'], {'ganador': 'ana', 'motivo': 'puntos'});
    });

    test('con los mismos puntos es empate', () {
      gestor.recibir('ana', jugada(1, puntos: 20, terminado: true));
      gestor.recibir('beto', jugada(1, puntos: 20, terminado: true));

      expect(ana.estado['resultado'], {'ganador': null, 'motivo': 'empate'});
    });

    test('rendirse le da la partida al rival', () {
      gestor.recibir('beto', {'tipo': 'rendirse'});

      expect(ana.estado['resultado'], {
        'ganador': 'ana',
        'motivo': 'rendicion',
      });
    });

    test('tambien se puede conceder mientras se ponen las anclas', () {
      gestor = GestorSalas(ajustes: ajustes, azar: AzarFijo());
      ana = CanalFalso();
      beto = CanalFalso();
      salaConLosDos();
      gestor.recibir('ana', {'tipo': 'empezar'});

      gestor.recibir('ana', {'tipo': 'rendirse'});

      expect(beto.estado['resultado'], {
        'ganador': 'beto',
        'motivo': 'rendicion',
      });
    });

    test('despues del final se puede salir y crear otra sala', () {
      gestor.recibir('beto', {'tipo': 'rendirse'});
      gestor.recibir('ana', {'tipo': 'salir_sala'});
      expect(ana.ultimo['tipo'], 'sin_sala');

      gestor.recibir('beto', {'tipo': 'crear_sala', 'nivel': 2});
      expect(beto.estado['fase'], 'espera');
      expect(beto.estado['nivel'], 2);
    });

    test('la sala terminada se borra sola al rato', () {
      fakeAsync((tiempo) {
        gestor = GestorSalas(ajustes: ajustes, azar: AzarFijo());
        enJuego();
        gestor.recibir('beto', {'tipo': 'rendirse'});
        expect(gestor.cuantasSalas, 1);

        tiempo.elapse(const Duration(minutes: 11));

        expect(gestor.cuantasSalas, 0);
      });
    });
  });

  group('desconexiones', () {
    test('al caerse, el rival lo ve desconectado con su cuenta regresiva', () {
      fakeAsync((tiempo) {
        enJuego();

        gestor.desconectar('beto', beto);

        expect(ana.jugador('beto')['conectado'], isFalse);
        expect(ana.jugador('beto')['segundosGracia'], 60);
        expect(ana.estado['fase'], 'juego');
      });
    });

    test('si vuelve a tiempo, sigue la partida donde estaba', () {
      fakeAsync((tiempo) {
        enJuego();
        gestor.recibir('beto', jugada(1, fila: 4, columna: 4));
        gestor.desconectar('beto', beto);
        tiempo.elapse(const Duration(seconds: 30));

        final nuevo = CanalFalso();
        gestor.conectar('beto', nuevo);

        expect(nuevo.estado['fase'], 'juego');
        expect(nuevo.estado['ronda'], 1);
        expect(nuevo.estado['mias'], [
          ...anclasBeto,
          [4, 4, 3]
        ]);
        expect(nuevo.jugador('beto')['jugoRonda'], isTrue);
        expect(ana.jugador('beto')['conectado'], isTrue);

        tiempo.elapse(const Duration(seconds: 60));
        expect(ana.estado['fase'], 'juego');
      });
    });

    test('si no vuelve a tiempo, el que se quedo gana por abandono', () {
      fakeAsync((tiempo) {
        enJuego();
        gestor.desconectar('beto', beto);

        tiempo.elapse(const Duration(seconds: 61));

        expect(ana.estado['resultado'], {
          'ganador': 'ana',
          'motivo': 'abandono',
        });
      });
    });

    test('el que volvio tarde ve el resultado al reconectarse', () {
      fakeAsync((tiempo) {
        enJuego();
        gestor.desconectar('beto', beto);
        tiempo.elapse(const Duration(seconds: 61));

        final nuevo = CanalFalso();
        gestor.conectar('beto', nuevo);

        expect(nuevo.estado['resultado'], {
          'ganador': 'ana',
          'motivo': 'abandono',
        });
      });
    });

    test('mientras uno esta caido el reloj de la ronda se para', () {
      fakeAsync((tiempo) {
        enJuego();
        gestor.desconectar('beto', beto);

        expect(ana.estado['segundosRonda'], isNull);
        tiempo.elapse(const Duration(seconds: 50));
        expect(ana.estado['ronda'], 1);

        final nuevo = CanalFalso();
        gestor.conectar('beto', nuevo);
        expect(nuevo.estado['segundosRonda'], 90);
      });
    });

    test('si se caen los dos y nadie vuelve, nadie gana', () {
      fakeAsync((tiempo) {
        enJuego();
        gestor.desconectar('ana', ana);
        tiempo.elapse(const Duration(seconds: 10));
        gestor.desconectar('beto', beto);

        tiempo.elapse(const Duration(seconds: 61));

        final nueva = CanalFalso();
        gestor.conectar('ana', nueva);
        expect(nueva.estado['resultado'], {
          'ganador': null,
          'motivo': 'abandonoAmbos',
        });
      });
    });

    test(
        'si al rival se le acabo la espera mientras uno estaba caido, '
        'gana el que vuelve', () {
      fakeAsync((tiempo) {
        enJuego();
        gestor.desconectar('ana', ana);
        tiempo.elapse(const Duration(seconds: 10));
        gestor.desconectar('beto', beto);
        tiempo.elapse(const Duration(seconds: 51));

        final nuevo = CanalFalso();
        gestor.conectar('beto', nuevo);

        expect(nuevo.estado['resultado'], {
          'ganador': 'beto',
          'motivo': 'abandono',
        });
      });
    });

    test('si los dos se caen y vuelve uno, se queda esperando al otro', () {
      fakeAsync((tiempo) {
        enJuego();
        gestor.desconectar('ana', ana);
        gestor.desconectar('beto', beto);
        tiempo.elapse(const Duration(seconds: 20));

        final nueva = CanalFalso();
        gestor.conectar('ana', nueva);
        tiempo.elapse(const Duration(seconds: 41));

        expect(nueva.estado['resultado'], {
          'ganador': 'ana',
          'motivo': 'abandono',
        });
      });
    });

    test('caerse en el lobby saca al invitado de la sala', () {
      salaConLosDos();

      gestor.desconectar('beto', beto);

      expect(ana.jugadores.map((j) => j['usuario']), ['ana']);
    });
  });

  group('puntos por orden de llegada', () {
    const tabla = {
      '1': [8, 6, 4],
      '2': [4, 3, 2],
    };

    void enJuegoConTabla() {
      conectarAmbos();
      gestor
          .recibir('ana', {'tipo': 'crear_sala', 'nivel': 1, 'puntos': tabla});
      gestor.recibir('beto', {
        'tipo': 'unirse',
        'codigo': ana.estado['codigo'],
      });
      gestor.recibir('ana', {'tipo': 'empezar'});
      gestor.recibir('ana', {'tipo': 'anclas', 'valores': anclasAna});
      gestor.recibir('beto', {'tipo': 'anclas', 'valores': anclasBeto});
    }

    Map<String, Object?> completa(int ronda, List<int> zonas, {int fila = 1}) =>
        {...jugada(ronda, fila: fila), 'zonas': zonas};

    test('quien completa primero una zona se lleva el puntaje mayor', () {
      enJuegoConTabla();
      gestor.recibir('ana', completa(1, [1]));
      gestor.recibir('beto', completa(1, []));
      gestor.recibir('ana', completa(2, [1], fila: 2));
      gestor.recibir('beto', completa(2, [1], fila: 2));

      expect(ana.jugador('ana')['puntos'], 8);
      expect(ana.jugador('beto')['puntos'], 6);
    });

    test('si la completan en la misma ronda, empatan con el mayor', () {
      enJuegoConTabla();
      gestor.recibir('ana', completa(1, [1]));
      gestor.recibir('beto', completa(1, [1]));

      expect(ana.jugador('ana')['puntos'], 8);
      expect(ana.jugador('beto')['puntos'], 8);
    });

    test('volver a reportar una zona no cambia cuando se completo', () {
      enJuegoConTabla();
      gestor.recibir('beto', completa(1, [1]));
      gestor.recibir('ana', completa(1, []));
      gestor.recibir('beto', completa(2, [1], fila: 2));
      gestor.recibir('ana', completa(2, [1], fila: 2));
      gestor.recibir('beto', completa(3, [1, 2], fila: 3));
      gestor.recibir('ana', completa(3, [1], fila: 3));

      expect(ana.jugador('beto')['puntos'], 8 + 4);
      expect(ana.jugador('ana')['puntos'], 6);
    });

    test('una zona completada con las anclas cuenta desde antes de jugar', () {
      conectarAmbos();
      gestor
          .recibir('ana', {'tipo': 'crear_sala', 'nivel': 1, 'puntos': tabla});
      gestor.recibir('beto', {
        'tipo': 'unirse',
        'codigo': ana.estado['codigo'],
      });
      gestor.recibir('ana', {'tipo': 'empezar'});
      gestor.recibir('ana', {
        'tipo': 'anclas',
        'valores': anclasAna,
        'zonas': [2],
      });
      gestor.recibir('beto', {'tipo': 'anclas', 'valores': anclasBeto});
      gestor.recibir('beto', completa(1, [2]));

      expect(beto.jugador('ana')['puntos'], 4);
      expect(beto.jugador('beto')['puntos'], 3);
    });

    test('el ganador se decide con los puntos del servidor', () {
      enJuegoConTabla();
      // Los dos reportan 99 puntos, pero ana llegó primero a la zona 1.
      gestor.recibir('ana', {
        ...completa(1, [1]),
        'puntos': 99,
        'terminado': true,
      });
      gestor.recibir('beto', {...completa(1, []), 'puntos': 99});
      gestor.recibir('beto', {
        ...completa(2, [1], fila: 2),
        'puntos': 99,
        'terminado': true,
      });

      expect(ana.estado['resultado'], {'ganador': 'ana', 'motivo': 'puntos'});
    });

    test('una zona que no esta en la tabla se rechaza', () {
      enJuegoConTabla();
      gestor.recibir('ana', completa(1, [77]));

      expect(ana.ultimoError?['error'], 'jugada_invalida');
    });

    test('una tabla mal formada no crea la sala', () {
      gestor.conectar('ana', ana);
      gestor.recibir('ana', {
        'tipo': 'crear_sala',
        'nivel': 1,
        'puntos': {'1': 'ocho'},
      });

      expect(ana.ultimoError?['error'], 'puntos_invalidos');
      expect(gestor.cuantasSalas, 0);
    });
  });
}
