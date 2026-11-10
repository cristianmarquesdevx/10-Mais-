import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:ten_map/ten_map.dart';

import '../../main.dart';
import '../api/client.dart';
import '../api/radar_api.dart';
import '../location/location_service.dart';
import '../theme/theme.dart';
import '../widgets/driver_radar.dart';
import '../widgets/radar_hud.dart';

/// C4 Fila (BUSCANDO) — mapa + radar de motoristas REAIS.
///
/// O radar usa a posição do aparelho (com fallback explícito para o embarque
/// do pedido) e a Edge Function `radar` (presença do parceiro). Sem backend
/// configurado, sem permissão de GPS ou sem parceiro online, a tela diz isso —
/// nunca desenha motorista sintético.
class FilaScreen extends StatefulWidget {
  const FilaScreen({super.key, this.location = const LocationService(), this.radar});

  /// Injetável para teste (sem plugin de plataforma).
  final LocationService location;
  final RadarApi? radar;

  @override
  State<FilaScreen> createState() => _FilaScreenState();
}

class _FilaScreenState extends State<FilaScreen> with WidgetsBindingObserver {
  Timer? _clock;
  Timer? _radarPoll;
  int _seg = 0;

  /// Com o app em segundo plano a varredura para: o timer do radar não é
  /// `Ticker`, então não ganha a pausa automática do vsync.
  bool _foreground = true;

  late final RadarApi _radar = widget.radar ?? RadarApi();

  /// Raio consultado. É o mesmo desenhado no HUD (anel externo).
  static const _radiusKm = 3.0;

  /// Zoom do mapa da busca (convenção OSM: o pacote converte para o MapLibre).
  static const _zoom = 13.4;

  LatLng? _center;
  bool _centerFromRide = false;
  LocationFailure? _locationFailure;
  bool _locating = true;
  bool _located = false;

  RadarSnapshot? _snapshot;
  String? _radarCode;
  bool _radarLoading = false;

  /// Câmera do mapa (vetorial ou raster): o HUD e os pinos se posicionam por
  /// ela, então precisam do mesmo estado.
  ///
  /// Fica num notifier (e não em `setState`): arrastar o mapa repinta só o
  /// HUD, sem refazer a tela inteira a cada quadro.
  final ValueNotifier<MapViewport?> _viewport = ValueNotifier(null);

  /// Varredura do radar. Ela NÃO roda no vsync: o mapa do passageiro ocupa a
  /// tela inteira e o HUD repinta por cima dele. A 60 quadros por segundo (um
  /// em cada 16 ms) o desenho custava mais que o próprio mapa e, num AVD com
  /// renderização por software, travava o emulador assim que um motorista
  /// entrava no raio. A 15 fps (66 ms) o giro continua legível e o custo da
  /// varredura cai a um quarto.
  static const _sweepStep = Duration(milliseconds: 66);
  static const _sweepPeriodMs = 2600;
  Timer? _sweepTimer;
  final ValueNotifier<double> _sweep = ValueNotifier<double>(0);

  /// Liga/desliga a varredura sem recriar o timer a cada rebuild.
  void _setSweep(bool active) {
    if (active == (_sweepTimer != null)) return;
    if (!active) {
      _sweepTimer?.cancel();
      _sweepTimer = null;
      return;
    }
    _sweepTimer = Timer.periodic(_sweepStep, (_) {
      _sweep.value =
          (_sweep.value + _sweepStep.inMilliseconds / _sweepPeriodMs) % 1;
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _clock = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _seg++);
      final ride = AppScope.of(context).ride;
      if (ride == null) return;
      if (ride.status.isCancelled) {
        Navigator.of(context).popUntil((r) => r.isFirst);
        return;
      }
      final destino = _telaPara(ride.status);
      if (destino != null) Navigator.pushReplacementNamed(context, destino);
    });
    // Atualiza o radar enquanto a corrida está em busca. O poll de status
    // (5 s) continua sendo o do RideController — este é só o do radar.
    _radarPoll = Timer.periodic(const Duration(seconds: 4), (_) {
      final ride = AppScope.of(context).ride;
      if (ride != null && ride.status.isSearching) _refreshRadar();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground || !mounted) return;
    setState(() => _foreground = foreground);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_located) return;
    _located = true;
    _locate();
  }

  Future<void> _locate() async {
    if (mounted) setState(() => _locating = true);
    final ride = AppScope.of(context).ride;
    try {
      final fix = await widget.location.current();
      if (!mounted) return;
      setState(() {
        _center = LatLng(fix.lat, fix.lon);
        _centerFromRide = false;
        _locationFailure = null;
        _locating = false;
        _viewport.value = null;
      });
      await _refreshRadar();
    } on LocationException catch (e) {
      if (!mounted) return;
      final origin = ride?.origin;
      setState(() {
        _locationFailure = e.failure;
        _locating = false;
        if (origin != null) {
          // Fallback declarado: o radar consulta o embarque que o pedido já
          // tinha. A tela avisa que o GPS do aparelho não está disponível.
          _center = LatLng(origin.lat, origin.lon);
          _centerFromRide = true;
        } else {
          _center = null;
        }
      });
      if (_center != null) {
        await _refreshRadar();
      }
    }
  }

  /// O painel flutuante cobre o rodapé: o mapa é centrado um pouco acima
  /// para o passageiro (e os anéis do radar) ficarem na área visível.
  LatLng _viewCenter(LatLng c) => LatLng(c.latitude + 0.0045, c.longitude);

  /// Marcadores do mapa: o ponto do passageiro e os motoristas por perto.
  List<MapMarker> _markers(LatLng center, {required bool searching}) {
    if (!searching) {
      return [
        MapMarker(
          point: center,
          width: 40,
          height: 40,
          child: const UserRadarDot(),
        ),
      ];
    }
    return radarMarkers(
      drivers: _snapshot?.drivers ?? const <RadarDriver>[],
      userPosition: center,
    );
  }

  Future<void> _refreshRadar() async {
    final c = _center;
    if (c == null || _radarLoading) return;
    if (!_radar.configured) {
      if (mounted) setState(() => _radarCode = 'radar_unconfigured');
      return;
    }
    setState(() => _radarLoading = true);
    try {
      final snap = await _radar.nearby(
        lat: c.latitude,
        lon: c.longitude,
        radiusKm: _radiusKm,
      );
      if (!mounted) return;
      setState(() {
        _snapshot = snap;
        _radarCode = null;
      });
    } on RadarProblem catch (p) {
      if (mounted) {
        setState(() {
          _radarCode = p.code;
          _snapshot = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _radarCode = 'radar_offline';
          _snapshot = null;
        });
      }
    } finally {
      if (mounted) setState(() => _radarLoading = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock?.cancel();
    _radarPoll?.cancel();
    _sweepTimer?.cancel();
    _sweep.dispose();
    _viewport.dispose();
    super.dispose();
  }

  static String? _telaPara(RideStatus s) {
    switch (s) {
      case RideStatus.aceita:
      case RideStatus.aCaminho:
      case RideStatus.chegou:
        return '/acompanhar';
      case RideStatus.emViagem:
        return '/viagem';
      case RideStatus.finalizada:
      case RideStatus.falhaPagamento:
        return '/pagamento';
      default:
        return null;
    }
  }

  String get _mmss =>
      '${(_seg ~/ 60).toString().padLeft(2, '0')}:${(_seg % 60).toString().padLeft(2, '0')}';

  int get _count => _snapshot?.eligibleCount ?? 0;

  String get _statusTitle {
    if (_locating) return 'Obtendo sua localização…';
    if (_center == null) return 'Ative a localização para buscar motoristas';
    if (_radarCode == 'radar_unconfigured') {
      return 'Radar indisponível nesta versão';
    }
    if (_radarCode != null) {
      return 'Sem conexão com o radar — tentando de novo…';
    }
    final ride = AppScope.of(context).ride;
    if (ride != null && !ride.status.isSearching) {
      return 'Motorista a caminho — aguarde o embarque';
    }
    if (_snapshot == null) return 'Procurando motorista por perto...';
    if (_count == 0) return 'Nenhum motorista por perto agora';
    return 'Procurando motorista por perto...';
  }

  String get _statusSubtitle {
    if (_locating) return 'A permissão de localização é usada só para a busca.';
    if (_center == null) {
      return 'Sem a posição do aparelho não há como saber quem está perto.';
    }
    if (_centerFromRide) {
      return 'GPS indisponível — usando o embarque do pedido como referência.';
    }
    if (_radarCode == 'radar_unconfigured') {
      return 'A busca real precisa do backend do radar configurado.';
    }
    if (_radarCode != null) return 'O contador volta quando a conexão retornar.';
    final snap = _snapshot;
    if (snap == null) return 'Consultando motoristas por perto…';
    final raio = snap.radiusKm.toStringAsFixed(0);
    return _count == 0
        ? 'Nenhum parceiro online num raio de $raio km.'
        : '$_count ${_count == 1 ? 'motorista' : 'motoristas'} num raio de $raio km.';
  }

  /// Conteúdo que cabe em qualquer altura (o mapa pode ficar baixo em telas
  /// pequenas/landscape) e rola em vez de estourar o layout.
  Widget _fitting(List<Widget> children) => LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: c.maxHeight),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.s),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: children,
                ),
              ),
            ),
          ),
        ),
      );

  Widget _mapArea() {
    final t = tokensOf(context);
    if (_locating) {
      return ColoredBox(
        color: t.background,
        child: _fitting([
          Icon(Icons.location_searching_rounded,
              size: 26, color: t.primary),
          const SizedBox(height: AppSpace.s),
          const Text('Obtendo sua localização…', style: AppType.label),
        ]),
      );
    }
    final center = _center;
    if (center == null) {
      return ColoredBox(
        color: t.background,
        child: _fitting([
          Icon(Icons.location_off_outlined,
              size: 32, color: t.primary),
          const SizedBox(height: AppSpace.s),
          Text(
            _locationFailure == LocationFailure.permissionDeniedForever
                ? 'Permissão de localização bloqueada'
                : 'Precisamos da sua localização',
            textAlign: TextAlign.center,
            style: AppType.title,
          ),
          const SizedBox(height: AppSpace.xs),
          const Text(
            'Sem ela não é possível mostrar motoristas próximos nem calcular '
            'o embarque.',
            textAlign: TextAlign.center,
            style: AppType.label,
          ),
          const SizedBox(height: AppSpace.m),
          FilledButton.icon(
            onPressed: () async {
              await widget.location.openSettings();
              if (mounted) _locate();
            },
            icon: const Icon(Icons.my_location_rounded, size: 18),
            label: const Text('Tentar de novo'),
          ),
        ]),
      );
    }

    final ride = AppScope.of(context).ride;
    final searching = ride != null && ride.status.isSearching;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Mapa compartilhado: vetorial (Console Noturno) no Android/iOS e
        // raster do OSM no fallback. Os pinos do radar são desenhados em
        // Flutter por cima — a mesma imagem nos dois backends.
        BaseMapView(
          center: _viewCenter(center),
          zoom: _zoom,
          userAgentPackageName: 'app.dezemais.passageiro',
          markers: _markers(center, searching: searching),
          onViewport: (viewport) => _viewport.value = viewport,
        ),
        if (searching && _radar.configured)
          // Só este pedaço repinta a cada passo da varredura: o HUD já está
          // numa RepaintBoundary própria (radar_hud.dart) e o mapa por baixo
          // não é refeito.
          ValueListenableBuilder<double>(
            valueListenable: _sweep,
            builder: (context, progress, _) => ValueListenableBuilder<MapViewport?>(
              valueListenable: _viewport,
              builder: (context, viewport, _) => RadarHud(
                viewport: viewport,
                center: center,
                radiusKm: _snapshot?.radiusKm ?? _radiusKm,
                progress: progress,
              ),
            ),
          ),
        if (searching) _countChip(),
        if (_radarLoading)
          const Positioned(
            top: 10,
            right: 10,
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        if (_centerFromRide)
          const Positioned(
            left: 10,
            top: 10,
            child: _MapNote(
              icon: Icons.location_searching_rounded,
              text: 'GPS indisponível · embarque do pedido',
            ),
          ),
      ],
    );
  }

  Widget _countChip() {
    final hasData = _snapshot != null && _radarCode == null;
    final text = !hasData
        ? 'Radar indisponível'
        : _count == 0
            ? 'Nenhum motorista na região'
            : '$_count ${_count == 1 ? 'motorista' : 'motoristas'} na região';
    return Positioned(
      left: 10,
      // Abaixo da AppBar (o mapa cobre a tela toda): o chip do contador fica
      // no topo do mapa, longe do painel flutuante do rodapé.
      top: 66,
      child: _MapNote(
        icon: hasData && _count > 0
            ? Icons.radar_rounded
            : Icons.info_outline_rounded,
        text: text,
        alert: !hasData || _count == 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final ride = controller.ride;
    final isSearching = ride != null && ride.status.isSearching;
    final showFare = ride != null && ride.fareTotal != null;
    final showProposal = controller.proposedAmount != null;
    final showTrip = ride != null &&
        (ride.destinationAddress != null || ride.originAddress != null);

    // A varredura só roda quando há radar real configurado: sem backend a
    // tela mostra o estado "indisponível" (e não uma animação decorativa que
    // também impediria testes de estabilizarem).
    final radarActive = isSearching &&
        _radar.configured &&
        _center != null &&
        _foreground;
    _setSweep(radarActive);

    return PopScope(
      canPop: false,
      child: Scaffold(
        // O radar vive DENTRO do mapa: o mapa cobre a tela inteira e os
        // controles flutuam por cima — topo com o status e o contador, rodapé
        // com valor, trajeto e ações. Nunca um radar fora do mapa.
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          title: const Text('Busca ativa'),
          backgroundColor: tokensOf(context).surface.withValues(alpha: 0.92),
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        body: LayoutBuilder(builder: (context, constraints) {
          final compact = constraints.maxHeight < 700;
          // O painel do rodapé NÃO repete o status: ele já flutua no topo do
          // mapa (_FloatingStatus). Aqui ficam só valor, trajeto e ações.
          final body = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_center == null)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.s),
                  child: TextButton.icon(
                    onPressed: _locate,
                    icon: const Icon(Icons.my_location_rounded, size: 18),
                    label: const Text('Tentar localizar de novo'),
                  ),
                ),
              Visibility(
                visible: showFare,
                child: Padding(
                  padding: const EdgeInsets.only(top: AppSpace.m),
                  child: Container(
                    padding: const EdgeInsets.all(AppSpace.l),
                    decoration: BoxDecoration(
                      color: tokensOf(context).primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(AppSpace.radiusCard),
                      border: Border.all(
                          color: tokensOf(context).primary.withValues(alpha: 0.35)),
                    ),
                    child: Row(children: [
                      Icon(Icons.savings_outlined,
                          color: tokensOf(context).earn, size: 20),
                      const SizedBox(width: AppSpace.m),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Valor da corrida',
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: tokensOf(context).earn)),
                            Text('Congelado do valor do momento do pedido',
                                style: AppType.label.copyWith(fontSize: 12)),
                          ],
                        ),
                      ),
                      Text(brl(ride?.fareTotal ?? 0), style: AppType.money),
                    ]),
                  ),
                ),
              ),
              Visibility(
                visible: showProposal,
                child: Padding(
                  padding: const EdgeInsets.only(top: AppSpace.m),
                  child: Text(
                      'Proposta: ${brl(controller.proposedAmount ?? 0)}',
                      style: AppType.title.copyWith(color: tokensOf(context).earn)),
                ),
              ),
              Visibility(
                visible: showTrip,
                child: Column(
                  children: [
                    const SizedBox(height: AppSpace.m),
                    if (ride != null) _TripSummary(ride: ride),
                  ],
                ),
              ),
              const _WhatHappensNext(),
              const SizedBox(height: AppSpace.l),
              OutlinedButton.icon(
                onPressed: () async {
                  final uri = await controller.share();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(uri?.toString() ??
                        'Link indisponível (${controller.lastErrorCode})'),
                  ));
                },
                icon: const Icon(Icons.share_outlined),
                label: const Text('Compartilhar viagem'),
              ),
              const SizedBox(height: AppSpace.m),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                    foregroundColor: tokensOf(context).danger),
                onPressed: controller.busy
                    ? null
                    : () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (dialogCtx) => AlertDialog(
                            title: Text(isSearching
                                ? 'Cancelar busca de motorista?'
                                : 'Cancelar corrida?'),
                            content: Text(isSearching
                                ? 'Os motoristas que receberam esta solicitacao nao '
                                    'serao mais notificados e a corrida sera encerrada.'
                                : 'A corrida sera cancelada e poderao ser aplicadas '
                                    'as regras de faltas (F7), se cabivel.'),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(dialogCtx).pop(false),
                                child: const Text('Nao'),
                              ),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                    backgroundColor: tokensOf(context).danger),
                                onPressed: () =>
                                    Navigator.of(dialogCtx).pop(true),
                                child: const Text('Sim, cancelar'),
                              ),
                            ],
                          ),
                        );
                        if (ok != true || !context.mounted) return;

                        final sucesso =
                            await controller.cancel('PASSENGER_REGRET');
                        if (!context.mounted) return;

                        if (sucesso) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(isSearching
                                  ? 'Busca cancelada com sucesso.'
                                  : 'Corrida cancelada.'),
                              backgroundColor: tokensOf(context).primary,
                            ),
                          );
                          Navigator.of(context).popUntil((r) => r.isFirst);
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                  'Nao foi possivel cancelar (${controller.lastErrorCode}). Tente novamente.'),
                              backgroundColor: tokensOf(context).danger,
                            ),
                          );
                        }
                      },
                child:
                    Text(isSearching ? 'Cancelar busca' : 'Cancelar corrida'),
              ),
            ],
          );
          return Stack(
            fit: StackFit.expand,
            children: [
              // Mapa de ponta a ponta: o radar, os anéis e os parceiros são
              // desenhados aqui, na mesma superfície em que o passageiro vê
              // sua própria posição.
              _mapArea(),
              SafeArea(
                child: Stack(
                  children: [
                    // Status flutua no topo do mapa; o painel, no rodapé.
                    // Posicionados (e não numa Column) para nenhuma altura
                    // de tela estourar o layout.
                    Positioned(
                      left: AppSpace.l,
                      right: AppSpace.l,
                      top: AppSpace.s,
                      child: _FloatingStatus(
                        time: _mmss,
                        title: _statusTitle,
                        subtitle: _statusSubtitle,
                        drivers: _snapshot == null ? null : _count,
                        onRetry: _center == null ? _locate : null,
                      ),
                    ),
                    Positioned(
                      left: AppSpace.l,
                      right: AppSpace.l,
                      bottom: AppSpace.l,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: constraints.maxHeight *
                              (compact ? 0.72 : 0.52),
                        ),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: tokensOf(context).surface,
                            borderRadius: BorderRadius.circular(
                                AppSpace.radiusSheet),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.16),
                                blurRadius: 22,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(AppSpace.l),
                            child: body,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        }),
      ),
    );
  }
}

/// Cartão flutuante do topo do mapa: tempo de espera, estado da busca e
/// quantos parceiros o radar encontrou. Fica sobre o mapa — o radar continua
/// visível entre este cartão e o painel do rodapé.
class _FloatingStatus extends StatelessWidget {
  const _FloatingStatus({
    required this.time,
    required this.title,
    required this.subtitle,
    this.drivers,
    this.onRetry,
  });

  final String time;
  final String title;
  final String subtitle;
  final int? drivers;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.l, vertical: AppSpace.m),
      decoration: BoxDecoration(
        color: t.surface.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(AppSpace.radiusSheet),
        border: Border.all(color: t.hairline.withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.14),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Text(time,
              style: AppType.display.copyWith(
                  fontSize: 30, color: t.primary, height: 1)),
          const SizedBox(width: AppSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.title.copyWith(fontSize: 14)),
                const SizedBox(height: 2),
                Text(subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.label.copyWith(fontSize: 11)),
              ],
            ),
          ),
          if (onRetry != null)
            IconButton(
              onPressed: onRetry,
              tooltip: 'Tentar localizar de novo',
              icon: Icon(Icons.my_location_rounded,
                  size: 18, color: t.primary),
            )
          else if (drivers != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: (drivers! > 0 ? t.primary : t.muted)
                    .withValues(alpha: 0.12),
                borderRadius:
                    BorderRadius.circular(AppSpace.radiusChip),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.radar_rounded,
                    size: 14,
                    color: drivers! > 0 ? t.primary : t.muted),
                const SizedBox(width: 5),
                Text('$drivers',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: drivers! > 0 ? t.primary : t.muted,
                    )),
              ]),
            ),
        ],
      ),
    );
  }
}

/// Etiqueta discreta sobre o mapa (contador/aviso de GPS).
class _MapNote extends StatelessWidget {
  const _MapNote({
    required this.icon,
    required this.text,
    this.alert = false,
  });

  final IconData icon;
  final String text;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: t.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(AppSpace.radiusChip),
        border: Border.all(color: t.hairline.withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: alert ? t.warning : t.primary),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: t.ink,
            ),
          ),
        ),
      ]),
    );
  }
}

/// Origem → destino do pedido atual, para a espera não ser uma tela vazia.
class _TripSummary extends StatelessWidget {
  const _TripSummary({required this.ride});

  final Ride ride;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Linha(
              icon: Icons.my_location_rounded,
              color: t.primary,
              titulo: 'Embarque',
              texto: ride.originAddress ?? 'Sua localizacao',
            ),
            const SizedBox(height: AppSpace.m),
            _Linha(
              icon: Icons.place_rounded,
              color: t.ink,
              titulo: 'Destino',
              texto: ride.destinationAddress ?? 'Destino escolhido',
            ),
          ],
        ),
      ),
    );
  }
}

class _Linha extends StatelessWidget {
  const _Linha({
    required this.icon,
    required this.color,
    required this.titulo,
    required this.texto,
  });

  final IconData icon;
  final Color color;
  final String titulo, texto;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: AppSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(titulo, style: AppType.label.copyWith(fontSize: 12)),
                Text(texto,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.body),
              ],
            ),
          ),
        ],
      );
}

/// Explica a espera: o app nao inventa ETA, quem calcula e o servidor.
class _WhatHappensNext extends StatelessWidget {
  const _WhatHappensNext();

  static const _passos = [
    'Enviamos seu pedido aos parceiros online por perto.',
    'Ao aceitar, voce ve nome, nota e veiculo antes do embarque.',
    'O valor da corrida fica congelado do momento do pedido.',
  ];

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('O que acontece agora', style: AppType.title),
          const SizedBox(height: AppSpace.s),
          for (var i = 0; i < _passos.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.s),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 20,
                    height: 20,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: t.primarySoft,
                      shape: BoxShape.circle,
                    ),
                    child: Text('${i + 1}',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: t.primary)),
                  ),
                  const SizedBox(width: AppSpace.m),
                  Expanded(
                    child: Text(_passos[i],
                        style: AppType.label.copyWith(fontSize: 13)),
                  ),
                ],
              ),
            ),
        ],
      );
}

}
