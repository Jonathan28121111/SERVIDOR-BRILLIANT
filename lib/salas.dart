import 'dart:async';
import 'dart:math';

import 'package:clock/clock.dart';

/// Por donde el gestor le habla a un jugador conectado. En producción es un
/// WebSocket; en las pruebas, una lista en memoria.
abstract interface class Canal {
  void enviar(Map<String, Object?> mensaje);
  void cerrar();
}

enum Fase { espera, anclas, juego, terminada }

/// Por qué terminó una partida.
enum Motivo { puntos, empate, rendicion, abandono, abandonoAmbos }

class Ajustes {
  /// Cuánto se espera a que vuelva un jugador que se cayó a media partida.
  final Duration graciaReconexion;

  /// Cuánto tiene cada jugador para jugar o pasar en una ronda.
  final Duration limiteRonda;

  /// Cuánto sigue viva una sala terminada para que vean el resultado.
  final Duration vidaSalaTerminada;

  /// Códigos equivocados permitidos por minuto, contra la fuerza bruta.
  final int fallosDeCodigoPorMinuto;

  const Ajustes({
    this.graciaReconexion = const Duration(seconds: 10),
    this.limiteRonda = const Duration(seconds: 90),
    this.vidaSalaTerminada = const Duration(minutes: 10),
    this.fallosDeCodigoPorMinuto = 10,
  });
}

/// Los puntos con que se acaba la partida, como en la tarjeta: 26 con dos
/// jugadores, 24 con tres, 22 con cuatro y 20 con cinco.
int metaDePuntos(int jugadores) => 30 - 2 * jugadores;

const int minimoJugadores = 2;
const int maximoJugadores = 5;

const int nivelMinimo = 1;
const int nivelMaximo = 4;
const int ladoMaximoTablero = 12;
const int largoCodigo = 6;

/// Sin 0/O ni 1/I/L, que se confunden al dictar el código.
const String letrasCodigo = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

class _Jugador {
  final String usuario;
  Canal? canal;
  bool listo = false;
  bool jugoRonda = false;
  bool terminado = false;

  /// Se rindió o no volvió a tiempo: la partida sigue sin él.
  bool fuera = false;

  /// Los puntos que calculó el cliente. Solo se usan si la sala no tiene
  /// tabla de puntos (clientes viejos).
  int puntosReportados = 0;
  final Map<(int, int), int> casillas = {};

  /// Zona completada -> ronda en que se completó (0 = con las anclas).
  final Map<int, int> zonas = {};
  Timer? gracia;
  DateTime? finGracia;

  _Jugador(this.usuario, this.canal);

  bool get conectado => canal != null;
  bool get yaJugo => jugoRonda || terminado || fuera;

  void cancelarGracia() {
    gracia?.cancel();
    gracia = null;
    finGracia = null;
  }
}

class _Sala {
  final String codigo;
  final int nivel;
  final String anfitrion;
  final List<_Jugador> jugadores = [];
  Fase fase = Fase.espera;
  int ronda = 0;
  (int, int)? dados;
  Timer? reloj;
  DateTime? finRonda;
  Timer? caducidad;
  String? ganador;
  Motivo? motivo;

  /// Se fija al empezar, con los jugadores que había.
  int? meta;

  /// Zona -> sus puntajes en orden de llegada, p. ej. [8, 6, 4]: quien la
  /// completa primero se lleva 8 y quien la completa después, 6.
  final Map<int, List<int>> tablaPuntos;

  _Sala(this.codigo, this.nivel, this.anfitrion, this.tablaPuntos);

  _Jugador? jugador(String usuario) {
    for (final j in jugadores) {
      if (_mismo(j.usuario, usuario)) return j;
    }
    return null;
  }

  bool get enCurso => fase == Fase.anclas || fase == Fase.juego;

  List<_Jugador> get activos => [
        for (final j in jugadores)
          if (!j.fuera) j,
      ];

  int get metaPuntos => meta ?? metaDePuntos(jugadores.length);

  void cancelarRelojes() {
    reloj?.cancel();
    reloj = null;
    finRonda = null;
    caducidad?.cancel();
    caducidad = null;
    for (final j in jugadores) {
      j.cancelarGracia();
    }
  }
}

bool _mismo(String a, String b) => a.toLowerCase() == b.toLowerCase();

/// Error que se le devuelve al jugador que mandó algo que no se puede hacer.
class ErrorSala implements Exception {
  final String clave;
  final String mensaje;

  const ErrorSala(this.clave, this.mensaje);
}

/// Lleva las salas, quién está en cada una y el estado de cada partida.
///
/// El servidor es el árbitro de lo que se comparte: los dados, las rondas,
/// el tiempo y quién sigue conectado. Cada cliente valida las reglas del
/// tablero y reporta su jugada y sus puntos.
class GestorSalas {
  final Ajustes ajustes;
  final Random _azar;

  final Map<String, Canal> _canales = {};
  final Map<String, _Sala> _salas = {};
  final Map<String, _Sala> _salaDe = {};
  final Map<String, List<DateTime>> _fallosCodigo = {};

  GestorSalas({this.ajustes = const Ajustes(), Random? azar})
      : _azar = azar ?? Random.secure();

  int get cuantasSalas => _salas.length;
  bool estaConectado(String usuario) =>
      _canales.containsKey(usuario.toLowerCase());

  // ---------------------------------------------------------------------
  // Conexiones

  void conectar(String usuario, Canal canal) {
    final llave = usuario.toLowerCase();
    final anterior = _canales[llave];
    if (anterior != null && !identical(anterior, canal)) {
      anterior.enviar({
        'tipo': 'reemplazada',
        'mensaje': 'Abriste el juego en otra ventana.',
      });
      anterior.cerrar();
    }
    _canales[llave] = canal;
    canal.enviar({'tipo': 'bienvenida', 'usuario': usuario});

    final sala = _salaDe[llave];
    if (sala == null) {
      canal.enviar({'tipo': 'sin_sala'});
      return;
    }
    final jugador = sala.jugador(usuario)!;
    if (jugador.fuera && sala.enCurso) {
      _salaDe.remove(llave);
      canal.enviar({'tipo': 'sin_sala'});
      return;
    }
    jugador.canal = canal;
    jugador.cancelarGracia();

    // Si los demás se cayeron y no volvieron mientras este jugador también
    // estaba caído, nadie más va a decidir la partida: gana quien volvió.
    final activos = sala.activos;
    if (sala.enCurso &&
        activos.length == 1 &&
        identical(activos.single, jugador)) {
      _terminar(sala, jugador.usuario, Motivo.abandono);
      return;
    }
    _ajustarReloj(sala);
    _difundir(sala);
  }

  void desconectar(String usuario, Canal canal) {
    final llave = usuario.toLowerCase();
    if (!identical(_canales[llave], canal)) {
      // Era una conexión vieja que ya se reemplazó.
      return;
    }
    _canales.remove(llave);

    final sala = _salaDe[llave];
    if (sala == null) return;
    final jugador = sala.jugador(usuario)!;
    jugador.canal = null;

    switch (sala.fase) {
      case Fase.espera:
      case Fase.terminada:
        _sacar(sala, jugador);
      case Fase.anclas:
      case Fase.juego:
        jugador.finGracia = clock.now().add(ajustes.graciaReconexion);
        jugador.gracia = Timer(
          ajustes.graciaReconexion,
          () => _seAcaboLaGracia(sala, jugador),
        );
        _ajustarReloj(sala);
        _difundir(sala);
    }
  }

  // ---------------------------------------------------------------------
  // Mensajes

  /// Atiende un mensaje del jugador. Si no se puede, le manda un error.
  void recibir(String usuario, Map<String, Object?> mensaje) {
    try {
      switch (mensaje['tipo']) {
        case 'crear_sala':
          _crearSala(usuario, mensaje['nivel'], mensaje['puntos']);
        case 'unirse':
          _unirse(usuario, mensaje['codigo']);
        case 'salir_sala':
          _salirSala(usuario);
        case 'empezar':
          _empezar(usuario);
        case 'anclas':
          _anclas(usuario, mensaje);
        case 'jugada':
          _jugada(usuario, mensaje);
        case 'pasar':
          _pasar(usuario, mensaje['ronda']);
        case 'rendirse':
          _rendirse(usuario);
        default:
          throw const ErrorSala(
            'mensaje_desconocido',
            'El servidor no entiende ese mensaje.',
          );
      }
    } on ErrorSala catch (error) {
      _canales[usuario.toLowerCase()]?.enviar({
        'tipo': 'error',
        'error': error.clave,
        'mensaje': error.mensaje,
      });
    }
  }

  void _crearSala(String usuario, Object? nivel, Object? puntos) {
    if (nivel is! int || nivel < nivelMinimo || nivel > nivelMaximo) {
      throw const ErrorSala('nivel_invalido', 'Ese nivel no existe.');
    }
    final tabla = _leerTabla(puntos);
    if (tabla == null) {
      throw const ErrorSala(
        'puntos_invalidos',
        'La tabla de puntos del tablero no es válida.',
      );
    }
    _dejarSalaTerminada(usuario);
    if (_salaDe.containsKey(usuario.toLowerCase())) {
      throw const ErrorSala('ya_en_sala', 'Ya estás en una sala.');
    }

    final sala = _Sala(_codigoNuevo(), nivel, usuario, tabla);
    sala.jugadores.add(_Jugador(usuario, _canales[usuario.toLowerCase()]));
    _salas[sala.codigo] = sala;
    _salaDe[usuario.toLowerCase()] = sala;
    _difundir(sala);
  }

  void _unirse(String usuario, Object? codigo) {
    if (_demasiadosFallos(usuario)) {
      throw const ErrorSala(
        'demasiados_intentos',
        'Demasiados códigos equivocados. Espera un minuto.',
      );
    }
    final limpio = codigo is String ? codigo.trim().toUpperCase() : '';
    final formatoValido = limpio.length == largoCodigo &&
        limpio.split('').every(letrasCodigo.contains);
    final sala = formatoValido ? _salas[limpio] : null;
    if (sala == null) {
      _anotarFallo(usuario);
      throw const ErrorSala(
        'sala_no_existe',
        'No hay ninguna sala con ese código.',
      );
    }

    _dejarSalaTerminada(usuario);
    final actual = _salaDe[usuario.toLowerCase()];
    if (actual != null) {
      throw ErrorSala(
        'ya_en_sala',
        identical(actual, sala)
            ? 'Ya estás en esa sala.'
            : 'Ya estás en otra sala.',
      );
    }
    if (sala.fase != Fase.espera) {
      throw const ErrorSala(
        'partida_empezada',
        'Esa partida ya empezó.',
      );
    }
    if (sala.jugadores.length >= maximoJugadores) {
      throw const ErrorSala('sala_llena', 'Esa sala ya está llena.');
    }

    sala.jugadores.add(_Jugador(usuario, _canales[usuario.toLowerCase()]));
    _salaDe[usuario.toLowerCase()] = sala;
    _difundir(sala);
  }

  void _salirSala(String usuario) {
    final sala = _salaDe[usuario.toLowerCase()];
    if (sala == null) {
      _canales[usuario.toLowerCase()]?.enviar({'tipo': 'sin_sala'});
      return;
    }
    if (sala.enCurso) {
      throw const ErrorSala(
        'partida_en_curso',
        'La partida está en curso: para salir tienes que rendirte.',
      );
    }
    _sacar(sala, sala.jugador(usuario)!);
    _canales[usuario.toLowerCase()]?.enviar({'tipo': 'sin_sala'});
  }

  void _empezar(String usuario) {
    final sala = _salaPropia(usuario);
    if (!_mismo(sala.anfitrion, usuario)) {
      throw const ErrorSala(
        'no_eres_anfitrion',
        'Solo quien creó la sala puede empezar.',
      );
    }
    if (sala.fase != Fase.espera) {
      throw const ErrorSala('partida_empezada', 'La partida ya empezó.');
    }
    if (sala.jugadores.length < minimoJugadores) {
      throw const ErrorSala('falta_rival', 'Todavía falta tu rival.');
    }
    sala.meta = metaDePuntos(sala.jugadores.length);
    sala.fase = Fase.anclas;
    _difundir(sala);
  }

  void _anclas(String usuario, Map<String, Object?> mensaje) {
    final valores = mensaje['valores'];
    final sala = _salaPropia(usuario);
    final jugador = sala.jugador(usuario)!;
    if (sala.fase != Fase.anclas) {
      throw const ErrorSala('fase_equivocada', 'No es momento de anclas.');
    }
    if (jugador.listo) {
      throw const ErrorSala('ya_listo', 'Ya mandaste tus anclas.');
    }

    final casillas = _leerCasillas(valores);
    if (casillas == null) {
      throw const ErrorSala('anclas_invalidas', 'Las anclas no son válidas.');
    }
    final numeros = casillas.values.toList();
    if (numeros.toSet().length != numeros.length) {
      throw const ErrorSala(
        'anclas_invalidas',
        'Cada número va en una sola ancla.',
      );
    }

    final zonas = _leerZonas(sala, mensaje['zonas']);
    if (zonas == null) {
      throw const ErrorSala('anclas_invalidas', 'Las zonas no son válidas.');
    }

    jugador.casillas.addAll(casillas);
    _anotarZonas(jugador, zonas, 0);
    jugador.listo = true;
    if (sala.activos.every((j) => j.listo)) {
      sala.fase = Fase.juego;
      _rondaNueva(sala);
    } else {
      _difundir(sala);
    }
  }

  void _jugada(String usuario, Map<String, Object?> mensaje) {
    final (sala, jugador) = _turnoDe(usuario, mensaje['ronda']);
    final fila = mensaje['fila'];
    final columna = mensaje['columna'];
    final numero = mensaje['numero'];
    final puntos = mensaje['puntos'];
    final terminado = mensaje['terminado'] == true;

    if (fila is! int ||
        columna is! int ||
        !_dentro(fila) ||
        !_dentro(columna) ||
        numero is! int ||
        puntos is! int ||
        puntos < 0 ||
        puntos > 10000) {
      throw const ErrorSala('jugada_invalida', 'La jugada no es válida.');
    }
    final (a, b) = sala.dados!;
    if (numero != a && numero != b) {
      throw const ErrorSala(
        'jugada_invalida',
        'Ese número no salió en los dados.',
      );
    }
    if (jugador.casillas.containsKey((fila, columna))) {
      throw const ErrorSala('jugada_invalida', 'Esa casilla ya está ocupada.');
    }
    final zonas = _leerZonas(sala, mensaje['zonas']);
    if (zonas == null) {
      throw const ErrorSala('jugada_invalida', 'Las zonas no son válidas.');
    }

    jugador.casillas[(fila, columna)] = numero;
    jugador.puntosReportados = puntos;
    _anotarZonas(jugador, zonas, sala.ronda);
    jugador.terminado = terminado;
    jugador.jugoRonda = true;
    _quizaCerrarRonda(sala);
  }

  void _pasar(String usuario, Object? ronda) {
    final (sala, jugador) = _turnoDe(usuario, ronda);
    jugador.jugoRonda = true;
    _quizaCerrarRonda(sala);
  }

  void _rendirse(String usuario) {
    final sala = _salaPropia(usuario);
    if (!sala.enCurso) {
      throw const ErrorSala('sin_partida', 'No hay ninguna partida en curso.');
    }
    _dejarFuera(sala, sala.jugador(usuario)!, Motivo.rendicion);
  }

  /// Saca de la partida a quien se rindió o no volvió. Si queda uno solo,
  /// gana; si quedan más, siguen jugando sin él.
  void _dejarFuera(_Sala sala, _Jugador jugador, Motivo motivo) {
    jugador.fuera = true;
    jugador.cancelarGracia();
    final activos = sala.activos;
    if (activos.isEmpty) {
      _terminar(sala, null, Motivo.abandonoAmbos);
      return;
    }
    if (activos.length == 1) {
      _terminar(sala, activos.single.usuario, motivo);
      return;
    }

    _salaDe.remove(jugador.usuario.toLowerCase());
    jugador.canal?.enviar({
      'tipo': 'sala_cerrada',
      'mensaje': motivo == Motivo.rendicion
          ? 'Te rendiste. La partida sigue sin ti.'
          : 'No volviste a tiempo. La partida siguió sin ti.',
    });
    jugador.canal = null;

    _ajustarReloj(sala);
    if (sala.fase == Fase.anclas && activos.every((j) => j.listo)) {
      sala.fase = Fase.juego;
      _rondaNueva(sala);
    } else if (sala.fase == Fase.juego) {
      _quizaCerrarRonda(sala);
    } else {
      _difundir(sala);
    }
  }

  // ---------------------------------------------------------------------
  // Rondas y final

  void _rondaNueva(_Sala sala) {
    sala.ronda++;
    sala.dados = (_azar.nextInt(6) + 1, _azar.nextInt(6) + 1);
    for (final j in sala.jugadores) {
      j.jugoRonda = false;
    }
    sala.reloj?.cancel();
    sala.reloj = null;
    _ajustarReloj(sala);
    _difundir(sala);
  }

  /// La meta solo se revisa al cerrar la ronda, para que todos jueguen con
  /// los mismos dados antes de decidir.
  void _quizaCerrarRonda(_Sala sala) {
    final activos = sala.activos;
    final rondaCompleta = activos.every((j) => j.yaJugo);
    final llegoALaMeta =
        activos.any((j) => _puntos(sala, j) >= sala.metaPuntos);
    if (activos.every((j) => j.terminado) || (rondaCompleta && llegoALaMeta)) {
      _terminarPorPuntos(sala);
    } else if (rondaCompleta) {
      _rondaNueva(sala);
    } else {
      _difundir(sala);
    }
  }

  /// El reloj de la ronda solo corre con todos conectados: si uno se cae,
  /// se para, y vuelve a empezar completo cuando regresa.
  void _ajustarReloj(_Sala sala) {
    final todos = sala.activos.every((j) => j.conectado);
    if (sala.fase != Fase.juego || !todos) {
      sala.reloj?.cancel();
      sala.reloj = null;
      sala.finRonda = null;
      return;
    }
    if (sala.reloj != null) return;
    final ronda = sala.ronda;
    sala.finRonda = clock.now().add(ajustes.limiteRonda);
    sala.reloj = Timer(ajustes.limiteRonda, () {
      sala.reloj = null;
      if (sala.fase != Fase.juego || sala.ronda != ronda) return;
      for (final j in sala.jugadores) {
        j.jugoRonda = true;
      }
      _quizaCerrarRonda(sala);
    });
  }

  void _seAcaboLaGracia(_Sala sala, _Jugador caido) {
    caido.gracia = null;
    caido.finGracia = null;
    if (!sala.enCurso || caido.conectado || caido.fuera) return;
    final otros = [
      for (final j in sala.activos)
        if (!identical(j, caido)) j,
    ];
    if (otros.any((j) => j.conectado)) {
      _dejarFuera(sala, caido, Motivo.abandono);
    } else if (otros.any((j) => j.gracia != null)) {
      // Los demás también están en su espera: se decide cuando vuelvan o
      // se les acabe a ellos.
      caido.fuera = true;
    } else {
      _terminar(sala, null, Motivo.abandonoAmbos);
    }
  }

  void _terminarPorPuntos(_Sala sala) {
    final activos = sala.activos;
    final puntos = [for (final j in activos) _puntos(sala, j)];
    final maximo = puntos.reduce(max);
    final mejores = [
      for (var i = 0; i < activos.length; i++)
        if (puntos[i] == maximo) activos[i],
    ];
    if (mejores.length > 1) {
      _terminar(sala, null, Motivo.empate);
    } else {
      _terminar(sala, mejores.single.usuario, Motivo.puntos);
    }
  }

  void _terminar(_Sala sala, String? ganador, Motivo motivo) {
    sala.cancelarRelojes();
    sala.fase = Fase.terminada;
    sala.ganador = ganador;
    sala.motivo = motivo;
    // La sala sigue viva un rato: quien estaba caído y vuelve ve el resultado.
    sala.caducidad = Timer(ajustes.vidaSalaTerminada, () => _cerrar(sala));
    _difundir(sala);
  }

  // ---------------------------------------------------------------------
  // Ayudantes

  void _sacar(_Sala sala, _Jugador jugador) {
    sala.jugadores.remove(jugador);
    _salaDe.remove(jugador.usuario.toLowerCase());

    if (sala.fase == Fase.espera && _mismo(jugador.usuario, sala.anfitrion)) {
      for (final otro in [...sala.jugadores]) {
        _salaDe.remove(otro.usuario.toLowerCase());
        otro.canal?.enviar({
          'tipo': 'sala_cerrada',
          'mensaje': 'Quien creó la sala se fue.',
        });
      }
      _cerrar(sala);
      return;
    }
    if (sala.jugadores.isEmpty) {
      _cerrar(sala);
      return;
    }
    _difundir(sala);
  }

  void _cerrar(_Sala sala) {
    sala.cancelarRelojes();
    _salas.remove(sala.codigo);
    for (final j in sala.jugadores) {
      if (identical(_salaDe[j.usuario.toLowerCase()], sala)) {
        _salaDe.remove(j.usuario.toLowerCase());
      }
    }
  }

  void _dejarSalaTerminada(String usuario) {
    final sala = _salaDe[usuario.toLowerCase()];
    if (sala != null && sala.fase == Fase.terminada) {
      _sacar(sala, sala.jugador(usuario)!);
    }
  }

  _Sala _salaPropia(String usuario) {
    final sala = _salaDe[usuario.toLowerCase()];
    if (sala == null) {
      throw const ErrorSala('sin_sala', 'No estás en ninguna sala.');
    }
    return sala;
  }

  (_Sala, _Jugador) _turnoDe(String usuario, Object? ronda) {
    final sala = _salaPropia(usuario);
    final jugador = sala.jugador(usuario)!;
    if (sala.fase != Fase.juego) {
      throw const ErrorSala('fase_equivocada', 'La partida no está en juego.');
    }
    if (ronda != sala.ronda) {
      throw const ErrorSala(
        'ronda_equivocada',
        'Esa ronda ya pasó.',
      );
    }
    if (jugador.yaJugo) {
      throw const ErrorSala('ya_jugaste', 'Ya jugaste esta ronda.');
    }
    return (sala, jugador);
  }

  static bool _dentro(int n) => n >= 0 && n < ladoMaximoTablero;

  /// Los puntos de un jugador según el orden en que completó cada zona.
  ///
  /// Su puesto en una zona es cuántos rivales la completaron en una ronda
  /// anterior: si la completan en la misma ronda, empatan y los dos se llevan
  /// el puntaje mayor. Después del último puntaje se repite el último.
  int _puntos(_Sala sala, _Jugador jugador) {
    if (sala.tablaPuntos.isEmpty) return jugador.puntosReportados;
    var total = 0;
    jugador.zonas.forEach((zona, ronda) {
      final valores = sala.tablaPuntos[zona];
      if (valores == null || valores.isEmpty) return;
      final antes = sala.jugadores
          .where((otro) => !identical(otro, jugador))
          .where((otro) => (otro.zonas[zona] ?? ronda) < ronda)
          .length;
      total += valores[min(antes, valores.length - 1)];
    });
    return total;
  }

  /// Anota solo las zonas nuevas: una zona completada se queda con la ronda
  /// en que se completó la primera vez.
  static void _anotarZonas(_Jugador jugador, Set<int> zonas, int ronda) {
    for (final zona in zonas) {
      jugador.zonas.putIfAbsent(zona, () => ronda);
    }
  }

  /// La tabla `{"1": [8, 6, 4], ...}` que manda quien crea la sala. Sin
  /// tabla queda vacía (clientes viejos); si viene mal, null.
  static Map<int, List<int>>? _leerTabla(Object? json) {
    if (json == null) return const {};
    if (json is! Map || json.length > 64) return null;
    final tabla = <int, List<int>>{};
    for (final MapEntry(:key, :value) in json.entries) {
      final zona = key is String ? int.tryParse(key) : null;
      if (zona == null ||
          value is! List ||
          value.isEmpty ||
          value.length > 3 ||
          value.any((v) => v is! int || v < 0 || v > 100)) {
        return null;
      }
      tabla[zona] = value.cast<int>();
    }
    return tabla;
  }

  /// Las zonas completas que reporta el cliente. Si la sala tiene tabla,
  /// solo valen las zonas que están en ella.
  static Set<int>? _leerZonas(_Sala sala, Object? json) {
    if (json == null) return const {};
    if (json is! List || json.length > 64) return null;
    final zonas = <int>{};
    for (final zona in json) {
      if (zona is! int) return null;
      if (sala.tablaPuntos.isNotEmpty && !sala.tablaPuntos.containsKey(zona)) {
        return null;
      }
      zonas.add(zona);
    }
    return zonas;
  }

  static Map<(int, int), int>? _leerCasillas(Object? valores) {
    if (valores is! List || valores.isEmpty || valores.length > 12) {
      return null;
    }
    final casillas = <(int, int), int>{};
    for (final v in valores) {
      if (v is! List || v.length != 3) return null;
      final [fila, columna, numero] = v;
      if (fila is! int ||
          columna is! int ||
          numero is! int ||
          !_dentro(fila) ||
          !_dentro(columna) ||
          numero < 1 ||
          numero > 6 ||
          casillas.containsKey((fila, columna))) {
        return null;
      }
      casillas[(fila, columna)] = numero;
    }
    return casillas;
  }

  String _codigoNuevo() {
    while (true) {
      final codigo = String.fromCharCodes([
        for (var i = 0; i < largoCodigo; i++)
          letrasCodigo.codeUnitAt(_azar.nextInt(letrasCodigo.length)),
      ]);
      if (!_salas.containsKey(codigo)) return codigo;
    }
  }

  bool _demasiadosFallos(String usuario) {
    final desde = clock.now().subtract(const Duration(minutes: 1));
    final lista = _fallosCodigo[usuario.toLowerCase()];
    lista?.removeWhere((t) => t.isBefore(desde));
    return (lista?.length ?? 0) >= ajustes.fallosDeCodigoPorMinuto;
  }

  void _anotarFallo(String usuario) {
    _fallosCodigo.putIfAbsent(usuario.toLowerCase(), () => []).add(clock.now());
  }

  void _difundir(_Sala sala) {
    for (final j in sala.jugadores) {
      j.canal?.enviar(_estadoPara(sala, j));
    }
  }

  Map<String, Object?> _estadoPara(_Sala sala, _Jugador quien) {
    final ahora = clock.now();
    int? segundosHasta(DateTime? fin) => fin == null
        ? null
        : max(0, (fin.difference(ahora).inMilliseconds / 1000).ceil());

    return {
      'tipo': 'estado',
      'codigo': sala.codigo,
      'nivel': sala.nivel,
      'anfitrion': sala.anfitrion,
      'fase': sala.fase.name,
      'ronda': sala.ronda,
      'dados': switch (sala.dados) {
        (final a, final b) => [a, b],
        null => null,
      },
      'segundosRonda': segundosHasta(sala.finRonda),
      'metaPuntos': sala.metaPuntos,
      'maximoJugadores': maximoJugadores,
      'jugadores': [
        for (final j in sala.jugadores)
          {
            'usuario': j.usuario,
            'conectado': j.conectado,
            'listo': j.listo,
            'puntos': _puntos(sala, j),
            'jugoRonda': j.jugoRonda,
            'terminado': j.terminado,
            'fuera': j.fuera,
            'zonas': {
              for (final MapEntry(key: zona, value: ronda) in j.zonas.entries)
                '$zona': ronda,
            },
            'segundosGracia': segundosHasta(j.finGracia),
          },
      ],
      'mias': [
        for (final MapEntry(key: (f, c), value: n) in quien.casillas.entries)
          [f, c, n],
      ],
      'resultado': sala.fase == Fase.terminada
          ? {'ganador': sala.ganador, 'motivo': sala.motivo!.name}
          : null,
    };
  }
}
