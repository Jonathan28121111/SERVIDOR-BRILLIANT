import 'dart:convert';
import 'dart:io';

import 'contrasenas.dart';
import 'usuario.dart';

enum FalloCuenta {
  nombreInvalido,
  contrasenaCorta,
  nombreOcupado,
  credencialesMalas,
}

class ResultadoCuenta {
  final Usuario? usuario;
  final FalloCuenta? fallo;

  const ResultadoCuenta.bien(Usuario this.usuario) : fallo = null;
  const ResultadoCuenta.mal(FalloCuenta this.fallo) : usuario = null;

  bool get salioBien => usuario != null;
}

class AlmacenUsuarios {
  static const int largoMinimoContrasena = 8;
  static const int largoMinimoNombre = 3;
  static const int largoMaximoNombre = 20;

  static final RegExp _nombreValido = RegExp(r'^[a-zA-Z0-9_.-]+$');

  final File _archivo;
  final Map<String, Usuario> _usuarios = {};

  AlmacenUsuarios(String ruta) : _archivo = File(ruta) {
    _cargar();
  }

  AlmacenUsuarios.enMemoria() : _archivo = File('');

  int get cuantos => _usuarios.length;

  Usuario? buscar(String nombre) => _usuarios[Usuario.normalizar(nombre)];

  bool existe(String nombre) => buscar(nombre) != null;

  ResultadoCuenta registrar(String nombre, String contrasena) {
    final limpio = nombre.trim();
    if (limpio.length < largoMinimoNombre ||
        limpio.length > largoMaximoNombre ||
        !_nombreValido.hasMatch(limpio)) {
      return const ResultadoCuenta.mal(FalloCuenta.nombreInvalido);
    }
    if (contrasena.length < largoMinimoContrasena) {
      return const ResultadoCuenta.mal(FalloCuenta.contrasenaCorta);
    }
    if (existe(limpio)) {
      return const ResultadoCuenta.mal(FalloCuenta.nombreOcupado);
    }

    final usuario = Usuario(
      nombre: limpio,
      contrasenaCifrada: Contrasenas.cifrar(contrasena),
      creado: DateTime.now().toUtc(),
    );
    _usuarios[usuario.llave] = usuario;
    _guardar();
    return ResultadoCuenta.bien(usuario);
  }

  ResultadoCuenta autenticar(String nombre, String contrasena) {
    final usuario = buscar(nombre);
    if (usuario == null) {
      Contrasenas.verificar(contrasena, _cifradoDeRelleno);
      return const ResultadoCuenta.mal(FalloCuenta.credencialesMalas);
    }
    if (!Contrasenas.verificar(contrasena, usuario.contrasenaCifrada)) {
      return const ResultadoCuenta.mal(FalloCuenta.credencialesMalas);
    }
    return ResultadoCuenta.bien(usuario);
  }

  bool borrar(String nombre) {
    final quitado = _usuarios.remove(Usuario.normalizar(nombre));
    if (quitado == null) {
      return false;
    }
    _guardar();
    return true;
  }

  void _cargar() {
    if (_archivo.path.isEmpty || !_archivo.existsSync()) {
      return;
    }
    final texto = _archivo.readAsStringSync().trim();
    if (texto.isEmpty) {
      return;
    }
    final lista = jsonDecode(texto) as List<dynamic>;
    for (final fila in lista) {
      final usuario = Usuario.deJson(fila as Map<String, dynamic>);
      _usuarios[usuario.llave] = usuario;
    }
  }

  void _guardar() {
    if (_archivo.path.isEmpty) {
      return;
    }
    _archivo.parent.createSync(recursive: true);
    final lista = _usuarios.values.map((u) => u.aJson()).toList();
    final temporal = File('${_archivo.path}.tmp');
    temporal.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(lista),
      flush: true,
    );
    temporal.renameSync(_archivo.path);
  }
}

final String _cifradoDeRelleno = Contrasenas.cifrar('usuario-inexistente');
