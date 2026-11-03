import 'dart:convert';
import 'dart:math';

class Sesiones {
  final Duration duracion;
  final Map<String, _Sesion> _abiertas = {};
  final Random _azar = Random.secure();

  Sesiones({this.duracion = const Duration(days: 7)});

  int get cuantas {
    _limpiar();
    return _abiertas.length;
  }

  String abrir(String usuario) {
    _limpiar();
    final token = _tokenNuevo();
    _abiertas[token] = _Sesion(
      usuario: usuario,
      expira: DateTime.now().toUtc().add(duracion),
    );
    return token;
  }

  String? usuarioDe(String? token) {
    if (token == null || token.isEmpty) {
      return null;
    }
    final sesion = _abiertas[token];
    if (sesion == null) {
      return null;
    }
    if (sesion.expira.isBefore(DateTime.now().toUtc())) {
      _abiertas.remove(token);
      return null;
    }
    return sesion.usuario;
  }

  void cerrar(String token) => _abiertas.remove(token);

  void cerrarTodasDe(String usuario) {
    final llave = usuario.toLowerCase();
    _abiertas.removeWhere((_, s) => s.usuario.toLowerCase() == llave);
  }

  String _tokenNuevo() {
    final bytes = List<int>.generate(32, (_) => _azar.nextInt(256));
    return base64Url.encode(bytes);
  }

  void _limpiar() {
    final ahora = DateTime.now().toUtc();
    _abiertas.removeWhere((_, s) => s.expira.isBefore(ahora));
  }
}

class _Sesion {
  final String usuario;
  final DateTime expira;

  const _Sesion({required this.usuario, required this.expira});
}

class Freno {
  final int intentosPermitidos;
  final Duration ventana;
  final Map<String, List<DateTime>> _fallos = {};

  Freno({
    this.intentosPermitidos = 5,
    this.ventana = const Duration(minutes: 15),
  });

  bool estaBloqueado(String usuario) {
    return _recientes(usuario).length >= intentosPermitidos;
  }

  void anotarFallo(String usuario) {
    final llave = usuario.toLowerCase();
    _fallos.putIfAbsent(llave, () => []).add(DateTime.now().toUtc());
  }

  void limpiar(String usuario) => _fallos.remove(usuario.toLowerCase());

  List<DateTime> _recientes(String usuario) {
    final llave = usuario.toLowerCase();
    final desde = DateTime.now().toUtc().subtract(ventana);
    final lista = _fallos[llave] ?? [];
    lista.removeWhere((t) => t.isBefore(desde));
    return lista;
  }
}
