/// Caminhos únicos dos assets empacotados no app.
///
/// Regra do projeto (M1): nenhuma tela usa string literal em `Image.asset`.
/// Todo caminho passa por aqui, e `test/assets_test.dart` carrega cada um com
/// `rootBundle` — se a pasta sair do `pubspec.yaml` ou o arquivo for
/// renomeado, o teste falha antes de virar "Asset not found" no aparelho.
///
/// O Flutter não é recursivo no `pubspec.yaml`: cada subpasta usada precisa
/// estar declarada com a barra final.
abstract final class AppAssets {
  static const _logos = 'assets/10-e-mais-logos/png';
  static const _carrosselLogin =
      'assets/10-e-mais-carrossel-login-sem-logo/png';
  static const _carrosselRaspadinha =
      'assets/10-e-mais-carrossel-raspadinha-sem-logo/png';

  // Logo oficial (3000x824). Usar `logoBranco` sobre fundo escuro/teal e
  // `logoTransparente` sobre fundo claro.
  static const logoCompleto = '$_logos/logo_completo.png';
  static const logoTransparente = '$_logos/logo_transparente.png';
  static const logoBranco = '$_logos/logo_branco.png';
  static const logoIcone = '$_logos/logo_icone.png';
  static const logoTexto = '$_logos/logo_texto.png';
  static const logoVertical = '$_logos/logo_vertical.png';

  // Pôsteres 1080x1230, SEM a logo embutida — a marca já aparece no topo da
  // tela. A versão 1080x1350 (com logo) não é empacotada nem usada.
  static const _slideGanhosMotorista =
      '$_carrosselLogin/05_ganhos_do_motorista.png';

  /// Login do passageiro: 01–04. O 05 (ganhos do motorista) é do parceiro.
  static const carrosselLoginSlides = <String>[
    '$_carrosselLogin/01_corrida_em_segundos.png',
    '$_carrosselLogin/02_entrega_com_foto.png',
    '$_carrosselLogin/03_aviso_de_chegada.png',
    '$_carrosselLogin/04_pague_do_seu_jeito.png',
  ];

  /// Todos os pôsteres de login que existem no bundle, inclusive o do
  /// motorista. Fonte do teste de assets.
  static const carrosselLoginTodos = <String>[
    ...carrosselLoginSlides,
    _slideGanhosMotorista,
  ];

  /// Pôsteres 1080x1230 da raspadinha, também sem logo.
  static const carrosselRaspadinhaSlides = <String>[
    '$_carrosselRaspadinha/01_raspe_e_ganhe.png',
    '$_carrosselRaspadinha/02_libere_raspadinhas.png',
    '$_carrosselRaspadinha/03_raspe_com_o_dedo.png',
    '$_carrosselRaspadinha/04_muitos_premios.png',
    '$_carrosselRaspadinha/05_premio_na_conta.png',
  ];

  /// Tudo o que precisa existir no bundle. Fonte do teste de assets.
  static const all = <String>[
    logoCompleto,
    logoTransparente,
    logoBranco,
    logoIcone,
    logoTexto,
    logoVertical,
    ...carrosselLoginTodos,
    ...carrosselRaspadinhaSlides,
  ];
}
