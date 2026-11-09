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
  static const _carrosselMotorista =
      'assets/10-e-mais-carrossel-motorista/png';

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
  /// Campanha do login do parceiro: 12 pôsteres 1080x1230 (01 → 12), na
  /// ordem de `slides.json`. O `CarouselDestaques` roda em autoplay e mostra
  /// os indicadores de página.
  static const carrosselMotoristaSlides = <String>[
    '$_carrosselMotorista/01_seja_parceiro.png',
    '$_carrosselMotorista/02_passe_ou_comissao.png',
    '$_carrosselMotorista/03_passe_100_por_cento.png',
    '$_carrosselMotorista/04_saldo_em_tempo_real.png',
    '$_carrosselMotorista/05_saque_por_pix.png',
    '$_carrosselMotorista/06_mapa_de_calor.png',
    '$_carrosselMotorista/07_corridas_e_entregas.png',
    '$_carrosselMotorista/08_foto_do_produto.png',
    '$_carrosselMotorista/09_alarme_de_chegada.png',
    '$_carrosselMotorista/10_documentos.png',
    '$_carrosselMotorista/11_suporte_24h.png',
    '$_carrosselMotorista/12_comece_agora.png',
  ];

  /// Todos os pôsteres de login que existem no bundle. Fonte do teste.
  static const carrosselLoginTodos = <String>[
    '$_carrosselLogin/01_corrida_em_segundos.png',
    '$_carrosselLogin/02_entrega_com_foto.png',
    '$_carrosselLogin/03_aviso_de_chegada.png',
    '$_carrosselLogin/04_pague_do_seu_jeito.png',
    '$_carrosselLogin/05_ganhos_do_motorista.png',
  ];

  /// Pôsteres 1080x1230 da raspadinha, também sem logo.
  static const carrosselRaspadinhaSlides = <String>[
    '$_carrosselRaspadinha/01_raspe_e_ganhe.png',
    '$_carrosselRaspadinha/02_libere_raspadinhas.png',
    '$_carrosselRaspadinha/03_raspe_com_o_dedo.png',
    '$_carrosselRaspadinha/04_muitos_premios.png',
    '$_carrosselRaspadinha/05_premio_na_conta.png',
  ];

  // Imagens de produto do app do parceiro.
  static const mapa = 'assets/map/mapa.jpg';
  static const apresentacao = 'assets/apresentacao/apresentacao.png';
  static const veiculoMoto = 'assets/vehicles/moto.png';
  static const veiculoCarro = 'assets/vehicles/carro.png';

  /// Tudo o que precisa existir no bundle. Fonte do teste de assets.
  static const all = <String>[
    logoCompleto,
    logoTransparente,
    logoBranco,
    logoIcone,
    logoTexto,
    logoVertical,
    ...carrosselLoginTodos,
    ...carrosselMotoristaSlides,
    ...carrosselRaspadinhaSlides,
    mapa,
    apresentacao,
    veiculoMoto,
    veiculoCarro,
  ];
}
