import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../api/client.dart';
import '../api/route_service.dart';
import '../location/location_service.dart';
import '../../main.dart';
import '../theme/theme.dart';
import '../widgets/route_map.dart';

/// C2 Destino/Confirmar — solicitar em ≤ 3 toques:
/// destino (pré-preenchido aqui) → pagamento pré-selecionado → "Chamar".
class DestinoScreen extends StatefulWidget {
  const DestinoScreen({
    super.key,
    this.initialDestination,
    this.initialLabel,
    this.location = const LocationService(),
  });

  /// "Repetir viagem": o destino da corrida antiga já entra escolhido, com o
  /// mapa traçado e a cotação do momento — o passageiro só confirma.
  final GeoPoint? initialDestination;
  final String? initialLabel;

  /// Injetável para teste (sem plugin de plataforma).
  final LocationService location;

  @override
  State<DestinoScreen> createState() => _DestinoScreenState();
}

class _DestinoScreenState extends State<DestinoScreen> {
  final _destino = TextEditingController();
  PricingMode _mode = PricingMode.tariff;
  double? _proposed;
  bool _sending = false;

  // Embarque = posição real do aparelho. O centro de Porto Velho continua
  // como fallback DECLARADO quando o GPS está indisponível — a tela avisa.
  GeoPoint _origem = const GeoPoint(-8.7607, -63.9039);
  LatLng _origemLL = const LatLng(-8.7607, -63.9039);
  bool _originLoading = true;
  bool _originFromDevice = false;
  LocationFailure? _originFailure;
  // Alvo fixo quando o usuário não escolhe uma sugestão (R1).
  static const _destinoFallback = GeoPoint(-8.7647, -63.8969);

  // Autocomplete de endereços reais (proxy Nominatim na demo).
  Timer? _debounce;
  List<PlaceResult> _suggestions = const [];
  bool _searching = false;
  PlaceResult? _chosen; // destino já geocodificado (não só texto)

  // Traçado real (OSRM) mostrado no mapa — km/min vêm daqui, não do palpite.
  RouteResult? _rota;

  // Preço do momento (GET /quote) — tarifa dinâmica do servidor.
  Quote? _quote;
  bool _quoting = false;
  Timer? _quoteDebounce;
  Timer? _quoteTicker; // reconta a validade e re-cota quando expira
  bool _prefilled = false;

  @override
  void initState() {
    super.initState();
    _loadOrigin();
  }

  Future<void> _loadOrigin() async {
    if (mounted) setState(() => _originLoading = true);
    try {
      final fix = await widget.location.current();
      if (!mounted) return;
      setState(() {
        _origem = GeoPoint(fix.lat, fix.lon);
        _origemLL = LatLng(fix.lat, fix.lon);
        _originFromDevice = true;
        _originFailure = null;
        _originLoading = false;
      });
      _refreshQuote();
    } on LocationException catch (e) {
      if (!mounted) return;
      setState(() {
        _originFailure = e.failure;
        _originLoading = false;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // AppScope.apiOf exige didChangeDependencies (não initState).
    if (_prefilled) return;
    _prefilled = true;
    final destino = widget.initialDestination;
    if (destino == null) return;
    // O label completo vai no pedido; o campo mostra só o trecho principal,
    // como quando o usuário escolhe uma sugestão de endereço.
    final label = widget.initialLabel ?? 'Destino anterior';
    // Número do endereço antigo também é obrigatório: reaproveita o que já
    // vinha no rótulo ("Shopping, 3288, Avenida...") quando existir.
    final m = RegExp(r',\s*(\d{1,6})\s*,').firstMatch(label);
    _chosen = PlaceResult(
      label: label,
      lat: destino.lat,
      lon: destino.lon,
      houseNumber: m?.group(1),
    );
    _destino.text = _chosen!.shortLabel;
    _refreshQuote();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _quoteDebounce?.cancel();
    _quoteTicker?.cancel();
    _destino.dispose();
    super.dispose();
  }

  void _onQueryChanged(String text) {
    setState(() {
      _chosen = null; // digitar de novo limpa a escolha
      _rota = null;
    });
    _debounce?.cancel();
    _quoteDebounce?.cancel();
    final q = text.trim();
    if (q.length < 3) {
      _quoteTicker?.cancel();
      setState(() {
        _suggestions = const [];
        _quote = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(q));
    // Preço do momento acompanha o que está sendo digitado (debounce próprio
    // para não cota a cada tecla).
    _quoteDebounce = Timer(const Duration(milliseconds: 500), _refreshQuote);
  }

  Future<void> _refreshQuote() async {
    if (_destino.text.trim().length < 3) return;
    final destino = _chosen != null
        ? GeoPoint(_chosen!.lat, _chosen!.lon)
        : _destinoFallback;
    setState(() => _quoting = true);
    try {
      final q = await AppScope.apiOf(context)
          .quote(origin: _origem, destination: destino);
      if (!mounted) return;
      setState(() {
        _quote = q;
        _quoting = false;
      });
      // Enquanto o valor vale, o contador corre; ao expirar, re-cota — o
      // servidor é quem manda no preço (SPECS).
      _quoteTicker?.cancel();
      _quoteTicker = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return t.cancel();
        if (_quote == null || _quote!.expired) {
          t.cancel();
          _refreshQuote();
        } else {
          setState(() {}); // reconta a validade
        }
      });
    } catch (_) {
      // Sem cotação a tela segue utilizável — o servidor decide no pedido.
      if (mounted) {
        setState(() {
          _quote = null;
          _quoting = false;
        });
      }
    }
  }

  Future<void> _search(String q) async {
    setState(() => _searching = true);
    try {
      final results = await AppScope.apiOf(context).geocode(q);
      if (!mounted) return;
      setState(() => _suggestions = results);
    } catch (_) {
      if (mounted) setState(() => _suggestions = const []);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// Escolhe a sugestão. Endereço sem número não fecha o pedido: pergunta o
  /// número (obrigatório) e re-geocodifica a via com ele.
  Future<void> _pick(PlaceResult p) async {
    var chosen = p;
    if (!chosen.hasNumber) {
      final numero = await _askNumber(chosen);
      if (numero == null) return; // desistiu: mantém o que estava
      chosen = await _applyNumber(chosen, numero);
    }
    if (!mounted) return;
    // Escolher fecha a busca: um debounce pendente não pode reabrir a lista
    // nem re-cotar por cima do endereço já confirmado.
    _debounce?.cancel();
    _quoteDebounce?.cancel();
    setState(() {
      _chosen = chosen;
      _rota = null;
      _suggestions = const [];
      // Mostra via + número; o endereço completo vai no pedido.
      _destino.text = chosen.shortLabel;
    });
    _refreshQuote(); // destino novo → preço do momento muda
  }

  /// Diálogo do número do imóvel. Sem número não há como o parceiro chegar
  /// ao ponto exato — por isso é campo obrigatório do pedido.
  Future<String?> _askNumber(PlaceResult p) async {
    final via = p.road?.isNotEmpty == true ? p.road! : p.label.split(',').first;
    final numero = await showDialog<String>(
      context: context,
      builder: (_) => _NumberDialog(via: via),
    );
    return (numero == null || numero.isEmpty) ? null : numero;
  }

  /// Re-geocodifica "via, número" e devolve o ponto do número. Se o serviço
  /// não achar o número exato, mantém o ponto da via e marca o número como
  /// informado pelo usuário (nunca inventa coordenada de imóvel).
  Future<PlaceResult> _applyNumber(PlaceResult p, String numero) async {
    final via = p.road?.isNotEmpty == true ? p.road! : p.label.split(',').first;
    try {
      final found = await AppScope.apiOf(context)
          .geocode('$via, $numero, Porto Velho');
      if (found.isNotEmpty) {
        final f = found.first;
        return PlaceResult(
          label: f.label,
          lat: f.lat,
          lon: f.lon,
          houseNumber: numero,
          numberFromUser: !f.hasNumber,
          road: via,
        );
      }
    } catch (_) {
      // rede/geocoder fora: segue com o ponto da via e o número informado
    }
    return p.withNumber(numero, fromUser: true);
  }

  Future<void> _chamar() async {
    final ride = AppScope.of(context);
    final api = AppScope.apiOf(context);
    if (_destino.text.trim().isEmpty) return;
    if (_chosen == null || !_chosen!.hasNumber) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Escolha o endereço e informe o número antes de chamar.'),
      ));
      return;
    }
    setState(() => _sending = true);
    // Usa as coordenadas reais do geocoding quando o usuário escolheu uma
    // sugestão; senão cai no alvo fixo (R1 — geocoding no servidor).
    final destino = _chosen != null
        ? GeoPoint(_chosen!.lat, _chosen!.lon)
        : _destinoFallback;
    // O servidor congela o valor que o passageiro viu — mas só enquanto a
    // cotação vale. Se ela venceu (tela parada, rede oscilou), re-cota antes
    // de chamar: cobrar um preço já expirado é o que o card promete não fazer.
    var cotacao = _quote;
    if (_mode == PricingMode.tariff && (cotacao == null || cotacao.expired)) {
      try {
        cotacao = await api.quote(origin: _origem, destination: destino);
        if (mounted) setState(() => _quote = cotacao);
      } catch (_) {
        cotacao = null; // sem cotação o servidor decide; o pedido segue
      }
    }
    await ride.requestRide(
      origin: _origem,
      destination: destino,
      mode: _mode,
      proposedAmount: _mode == PricingMode.negotiated ? _proposed : null,
      // TARIFF: o valor que o passageiro está vendo agora (snapshot).
      quotedFare: _mode == PricingMode.tariff ? cotacao?.fareTotal : null,
      originAddress: _originFromDevice
          ? 'Sua localização atual'
          : 'Embarque padrão — Centro',
      // Rótulo com o número garantido (o geocoder pode não trazer o número;
      // o parceiro precisa dele para chegar ao ponto exato).
      destinationAddress: _chosen!.requestLabel,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    final code = ride.lastErrorCode;
    if (code == null) {
      Navigator.pushNamed(context, '/fila');
    } else {
      // Decisão por code (problem+json) — F2: erro de preço = retry+negociar.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(switch (code) {
          'active_ride_exists' => 'Você já tem uma corrida em andamento.',
          'below_floor' =>
            'Proposta abaixo do mínimo da cidade. Ajuste o valor.',
          'invalid_pricing' => 'Preço indisponível agora. Tente de novo.',
          _ => 'Não foi possível chamar. ($code)',
        }),
        action: code == 'invalid_pricing'
            ? SnackBarAction(
                label: 'Negociar',
                onPressed: () => Navigator.pushNamed(context, '/negociar'))
            : null,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ride = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Confirmar destino')),
      body: Column(children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(AppSpace.l),
            children: [
              // Campo de destino com autocomplete de endereços reais.
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _destino,
                    onChanged: _onQueryChanged,
                    decoration: InputDecoration(
                      hintText: 'Para onde?',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searching
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: Padding(
                                padding: EdgeInsets.all(12),
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                            )
                          : null,
                    ),
                    textInputAction: TextInputAction.done,
                  ),
                  if (_chosen != null)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpace.xs),
                      child: Text(
                        _chosen!.label,
                        style: AppType.label.copyWith(color: AppColors.primary),
                      ),
                    ),
                  // Endereço sem número não vira pedido: o CTA fica travado
                  // até o número existir (nada de embarque em ponto genérico).
                  if (_chosen == null || !_chosen!.hasNumber)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpace.xs),
                      child: Row(children: [
                        const Icon(Icons.info_outline,
                            size: 14, color: AppColors.warning),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _chosen == null
                                ? 'Escolha um endereço com número para chamar.'
                                : 'Falta o número do endereço para chamar.',
                            style: AppType.label.copyWith(fontSize: 11),
                          ),
                        ),
                        if (_chosen != null)
                          TextButton(
                            onPressed: () => _pick(_chosen!),
                            child: const Text('Incluir número'),
                          ),
                      ]),
                    ),
                  if (_suggestions.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: AppSpace.xs),
                      constraints: const BoxConstraints(maxHeight: 240),
                      // Material próprio: ListTile pinta fundo/ripple no Material
                      // ancestral — sem ele o Flutter lança exceção de renderização.
                      child: Material(
                        color: AppColors.surface,
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(AppSpace.radiusCard),
                          side: BorderSide(
                              color: AppColors.hairline.withValues(alpha: 0.4)),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: ListView.builder(
                          padding: EdgeInsets.zero,
                          shrinkWrap: true,
                          itemCount: _suggestions.length,
                          itemBuilder: (context, i) {
                            final p = _suggestions[i];
                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.location_on_outlined,
                                  color: AppColors.primary, size: 20),
                              title: Text(p.label,
                                  maxLines: 2, overflow: TextOverflow.ellipsis),
                              onTap: () => _pick(p),
                            );
                          },
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpace.l),
              _OriginBanner(
                loading: _originLoading,
                fromDevice: _originFromDevice,
                failure: _originFailure,
                onRetry: _loadOrigin,
              ),
              const SizedBox(height: AppSpace.s),
              // Mapa real: mostra a origem e, assim que houver destino escolhido,
              // o traçado por ruas com km/min de verdade.
              RouteMap(
                origin: _origemLL,
                destination:
                    _chosen == null ? null : LatLng(_chosen!.lat, _chosen!.lon),
                onRoute: (r) {
                  if (mounted) setState(() => _rota = r);
                },
              ),
              if (_rota != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpace.s),
                  child: Row(children: [
                    Icon(
                        _rota!.approx
                            ? Icons.moving_outlined
                            : Icons.route_rounded,
                        size: 16,
                        color:
                            _rota!.approx ? AppColors.muted : AppColors.earn),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _rota!.approx
                            ? 'Traçado aproximado (${_rota!.label}) — sem rota por ruas agora'
                            : 'Trajeto por ruas: ${_rota!.label} até o destino',
                        style: AppType.label.copyWith(fontSize: 12),
                      ),
                    ),
                  ]),
                ),
              const SizedBox(height: AppSpace.l),
              _PricingCard(quote: _quote, quoting: _quoting, mode: _mode),
              const SizedBox(height: AppSpace.l),
              RadioGroup<PricingMode>(
                groupValue: _mode,
                onChanged: (v) => setState(() => _mode = v!),
                child: const Column(children: [
                  RadioListTile<PricingMode>(
                    value: PricingMode.tariff,
                    title: Text('Pela tarifa'),
                    subtitle: Text('Preço fechado, sem negociação'),
                  ),
                  RadioListTile<PricingMode>(
                    value: PricingMode.negotiated,
                    title: Text('Negociar preço'),
                    subtitle:
                        Text('Você propõe; o parceiro aceita ou contrapõe'),
                  ),
                ]),
              ),
              if (_mode == PricingMode.negotiated) ...[
                const SizedBox(height: AppSpace.s),
                TextField(
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Sua proposta (R\$)',
                    helperText: _quote != null
                        ? 'Tarifa do momento: ${brl(_quote!.fareTotal)} · entre 70% e 300%'
                        : 'Entre 70% e 300% da tarifa — o servidor valida',
                  ),
                  onChanged: (v) =>
                      _proposed = double.tryParse(v.replaceAll(',', '.')),
                ),
              ],
              const SizedBox(height: AppSpace.l),
            ],
          ),
        ),
        // CTA fixo: "Chamar" fica sempre visível, sem rolar a tela — o fluxo
        // C1→C2 continua em ≤ 3 toques mesmo com o mapa em cima.
        SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(
                AppSpace.l, AppSpace.m, AppSpace.l, AppSpace.m),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border(
                  top:
                      BorderSide(color: AppColors.ink.withValues(alpha: 0.06))),
            ),
            child: FilledButton(
              onPressed: _sending || _chosen == null || !_chosen!.hasNumber
                  ? null
                  : _chamar,
              child: _sending
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(ride.busy ? 'Chamando…' : 'Chamar'),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Preço do momento (GET /quote): tarifa dinâmica visível ANTES de chamar.
/// O valor muda com a demanda/hora — o card mostra a validade, re-conta e
/// re-cota sozinho; no modo negociado vira referência para a proposta.
class _PricingCard extends StatelessWidget {
  const _PricingCard(
      {required this.quote, required this.quoting, required this.mode});

  final Quote? quote;
  final bool quoting;
  final PricingMode mode;

  @override
  Widget build(BuildContext context) {
    final has = quote != null;
    final secs = has
        ? (quote!.expiresAt.difference(DateTime.now()).inSeconds).clamp(0, 999)
        : 0;
    final expiring = has && secs <= 15;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpace.l),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppSpace.radiusCard),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.savings_outlined, color: AppColors.earn, size: 18),
            const SizedBox(width: 6),
            const Text('Valor no momento',
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: AppColors.earn)),
            const Spacer(),
            if (quoting && !has)
              const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
            else if (has)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.s, vertical: 2),
                decoration: BoxDecoration(
                  color: (expiring ? AppColors.warning : AppColors.primary)
                      .withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(AppSpace.radiusChip),
                ),
                child: Text(
                  expiring ? 'atualiza em ${secs}s' : 'vale por ${secs}s',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: expiring ? AppColors.warning : AppColors.earn),
                ),
              ),
          ]),
          const SizedBox(height: AppSpace.s),
          if (has) Text(brl(quote!.fareTotal), style: AppType.display),
          if (has && _breakdown(quote!) != null) ...[
            const SizedBox(height: 2),
            Text(_breakdown(quote!)!,
                style: AppType.label.copyWith(fontSize: 11)),
          ],
          const SizedBox(height: AppSpace.xs),
          Text(
            has
                ? (mode == PricingMode.negotiated
                    ? 'Use como referência da sua proposta.'
                    : 'Tarifa dinâmica — o servidor congela este valor no pedido.')
                : quoting
                    ? 'Calculando o valor da rota…'
                    : 'Digite o destino para ver a tarifa do momento.',
            style: AppType.label.copyWith(fontSize: 12),
          ),
        ],
      ),
    );
  }

  /// De onde vem o número: base + km da rota × demanda da zona × hora.
  /// Sem isso o valor parece arbitrário quando muda entre uma consulta e
  /// outra (rush ×1,18, madrugada ×0,88).
  static String? _breakdown(Quote q) {
    final b = q.breakdown;
    if (b == null) return null;
    final km = (b['distance_km'] as num?)?.toDouble();
    final base = (b['base'] as num?)?.toDouble();
    final demand = (b['demand_multiplier'] as num?)?.toDouble();
    final rush = (b['rush_multiplier'] as num?)?.toDouble();
    if (km == null || base == null || demand == null || rush == null) {
      return null;
    }
    String x(double v) => '×${v.toStringAsFixed(2).replaceAll('.', ',')}';
    return 'Base ${brl(base)} · ${RouteResult.kmLabel(km)} · '
        'demanda ${x(demand)} · hora ${x(rush)}';
  }
}

/// De onde sai o embarque: GPS real, carregando ou fallback declarado.
class _OriginBanner extends StatelessWidget {
  const _OriginBanner({
    required this.loading,
    required this.fromDevice,
    required this.failure,
    required this.onRetry,
  });

  final bool loading;
  final bool fromDevice;
  final LocationFailure? failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Row(children: [
        const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: AppSpace.s),
        Text('Obtendo sua localização…',
            style: AppType.label.copyWith(fontSize: 12)),
      ]);
    }
    if (fromDevice) {
      return Row(children: [
        const Icon(Icons.my_location_rounded,
            size: 15, color: AppColors.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text('Embarque na sua localização atual',
              style: AppType.label.copyWith(fontSize: 12)),
        ),
      ]);
    }
    final reason = switch (failure) {
      LocationFailure.permissionDenied ||
      LocationFailure.permissionDeniedForever =>
        'Permissão de localização negada',
      LocationFailure.serviceDisabled => 'GPS desligado',
      LocationFailure.timeout => 'GPS sem resposta',
      _ => 'GPS indisponível',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppSpace.radiusCard),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(children: [
        const Icon(Icons.location_off_outlined,
            size: 15, color: AppColors.warning),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '$reason — embarque padrão no Centro. Toque em tentar para usar '
            'sua posição real.',
            style: AppType.label.copyWith(fontSize: 12),
          ),
        ),
        TextButton(
          onPressed: onRetry,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 32),
          ),
          child: const Text('Tentar'),
        ),
      ]),
    );
  }
}

/// Diálogo do número do imóvel: dono do próprio TextEditingController, para
/// não usá-lo depois de descartado quando o diálogo fecha.
class _NumberDialog extends StatefulWidget {
  const _NumberDialog({required this.via});

  final String via;

  @override
  State<_NumberDialog> createState() => _NumberDialogState();
}

class _NumberDialogState extends State<_NumberDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _confirmar() {
    final v = _ctrl.text.trim();
    if (v.isEmpty) return;
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Número do endereço'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.via, style: AppType.label),
          const SizedBox(height: AppSpace.s),
          TextField(
            controller: _ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Número da casa / estabelecimento',
              hintText: 'Ex.: 3288',
            ),
            onSubmitted: (_) => _confirmar(),
          ),
          const SizedBox(height: AppSpace.xs),
          const Text(
            'O número é obrigatório para o parceiro localizar o embarque.',
            style: TextStyle(fontSize: 11),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _confirmar,
          child: const Text('Confirmar'),
        ),
      ],
    );
  }
}
