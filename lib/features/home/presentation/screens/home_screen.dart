
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import '../../home_models.dart';
import '../../home_events.dart';
import '../../application/controllers/home_controller.dart';

class HomeScreen extends StatefulWidget {
  final HomeController controller;
  final bool disposeController;
  final VoidCallback? onOpenMenu;
  final bool mapOnlyMode;

  const HomeScreen({
    super.key,
    required this.controller,
    this.disposeController = true,
    this.onOpenMenu,
    this.mapOnlyMode = false,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const String _extrusionLayerId = 'rt-3d-buildings';
  static const String _roofLayerId = 'rt-3d-buildings-top';
  static const double _buildingsMinZoom = 13.2;
  static const Duration _buildingsDebounce = Duration(milliseconds: 900);
  late final HomeController controller;
  late final bool _ownsController;
  final MapController _mapController = MapController();
  ml.MaplibreMapController? _mapLibreController;
  Timer? _osm3dDebounce;
  bool _osmSourceAdded = false;
  int _osmRequestSeq = 0;
  final Map<String, List<_StyleLayerRef>> _buildingTargetsCache = {};
  final Map<String, _StyleLayerRef?> _roadTargetsCache = {};
  final Map<String, List<String>> _poiIconLayerIdsCache = {};
  Timer? _retryEnsure3dTimer;
  LatLng? _pendingStyleRestoreCenter;
  double? _pendingStyleRestoreZoom;
  String? _active3dLayerKey;
  _OsmViewportSnapshot? _lastOsmViewport;
  Timer? _styleLoadWatchdog;
  int _styleLoadRetries = 0;
  int _mapReloadSeq = 0;
  final Map<String, Map<String, dynamic>> _styleJsonByUri = {};

  bool _threeDMode = true;
  double _tiltFactor = 0.62;
  bool _showBusinessPoiIcons = true;
  String? _resolvedThemeStyleString;
  String? _resolvedThemeStyleKey;
  String? _symbolAnchorLayerId;
  bool _mapInteractionsLocked = false;

  bool get _supportsMapLibre =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  bool get _useMapLibre => _supportsMapLibre;
  double get _currentTilt => (60.0 * _tiltFactor).clamp(0.0, 60.0);
  double get _currentBearing => _tiltFactor > 0.01 ? 20.0 : 0.0;

  @override
  void initState() {
    super.initState();
    controller = widget.controller;
    _ownsController = widget.disposeController;
    controller.messageSink = _showSnack;
    controller.addListener(_onUpdate);
    _refreshThemeStyleIfNeeded();
  }

  @override
  void dispose() {
    _osm3dDebounce?.cancel();
    _styleLoadWatchdog?.cancel();
    _retryEnsure3dTimer?.cancel();
    controller.removeListener(_onUpdate);
    controller.messageSink = null;
    if (_ownsController) {
      controller.dispose();
    }
    super.dispose();
  }

  void _onUpdate() {
    _applyPendingMapMoveIfAny();
    _refreshThemeStyleIfNeeded();
    setState(() {});
  }

  void _applyPendingMapMoveIfAny() {
    final pending = controller.takePendingMapMove();
    if (pending == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_useMapLibre && _mapLibreController != null) {
        _moveMapLibreCamera(
          center: pending.center,
          zoom: pending.zoom,
          animated: false,
        );
        return;
      }

      try {
        _mapController.move(pending.center, pending.zoom);
      } catch (_) {}
    });
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: Colors.black.withOpacity(0.78),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  Future<void> _openCitySheet() async {
    setState(() => _mapInteractionsLocked = true);
    final selected = await showModalBottomSheet<City>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _CityPicker(
        cities: controller.cities,
        selectedCity: controller.selectedCity,
      ),
    );
    if (mounted) {
      setState(() => _mapInteractionsLocked = false);
    }

    if (selected != null && selected.id != controller.selectedCity.id) {
      _pendingStyleRestoreCenter = null;
      _pendingStyleRestoreZoom = null;
      controller.selectCity(selected);
      _moveMapLibreCamera(
        center: selected.center,
        zoom: selected.defaultZoom,
        animated: true,
      );
    }
  }

  void _onMapLibreCreated(ml.MaplibreMapController map) {
    _mapLibreController = map;
    _startStyleLoadWatchdog();
    _moveMapLibreCamera(
      center: controller.mapCenter,
      zoom: controller.mapZoom,
      animated: false,
    );
  }

  Future<void> _onMapLibreStyleLoaded() async {
    _styleLoadWatchdog?.cancel();
    _styleLoadRetries = 0;
    _active3dLayerKey = null;
    _lastOsmViewport = null;

    final restoreCenter = _pendingStyleRestoreCenter;
    final restoreZoom = _pendingStyleRestoreZoom;
    _pendingStyleRestoreCenter = null;
    _pendingStyleRestoreZoom = null;
    if (restoreCenter != null && restoreZoom != null) {
      _moveMapLibreCamera(
        center: restoreCenter,
        zoom: restoreZoom,
        animated: false,
      );
    }

    await _enforceRussianMapLanguage();
    await _applyRuntimeThemePalette();
    _symbolAnchorLayerId = await _resolveSymbolAnchorLayerId();
    if (!kIsWeb) {
      await _setPrivatePoiIconsVisibility(_showBusinessPoiIcons);
    }
    if (!widget.mapOnlyMode) {
      await _showOnlyStreetLabels();
    }
    _osm3dDebounce?.cancel();
    _osm3dDebounce = Timer(const Duration(milliseconds: 800), () async {
      final added3d = await _ensure3dBuildings();
      if (!added3d) {
        _retryEnsure3dTimer?.cancel();
        _retryEnsure3dTimer = Timer(const Duration(seconds: 2), () {
          _ensure3dBuildings();
        });
      }
    });
  }

  void _moveMapLibreCamera({
    required LatLng center,
    required double zoom,
    bool animated = true,
  }) {
    final map = _mapLibreController;
    if (map == null) return;

    final camera = ml.CameraUpdate.newCameraPosition(
      ml.CameraPosition(
        target: ml.LatLng(center.latitude, center.longitude),
        zoom: zoom,
        tilt: _currentTilt,
        bearing: _currentBearing,
      ),
    );

    if (animated) {
      map.animateCamera(camera);
    } else {
      map.moveCamera(camera);
    }
  }

  Future<void> _setMapMode3d(bool enabled) async {
    if (!_useMapLibre) {
      _showSnack('3D доступен на Android/iOS. Сейчас активен 2D-режим.');
      return;
    }
    final viewport = await _readMapLibreViewport();
    setState(() {
      _threeDMode = enabled;
      _tiltFactor = enabled ? 1.0 : 0.0;
    });
    _moveMapLibreCamera(
      center: viewport.center,
      zoom: viewport.zoom,
      animated: true,
    );

    if (enabled) {
      _ensure3dBuildings();
    }
  }

  Future<void> _onMapLibreCameraIdle() async {
    final viewport = await _readMapLibreViewport();
    controller.updateMapViewport(center: viewport.center, zoom: viewport.zoom);
    final map = _mapLibreController;
    if (map != null) {
      try {
        final pos = await map.queryCameraPosition();
        final tilt = (pos?.tilt ?? 0.0).toDouble().clamp(0.0, 60.0).toDouble();
        final factor = (tilt / 60.0).clamp(0.0, 1.0).toDouble();
        final next3d = factor > 0.01;
        if ((factor - _tiltFactor).abs() > 0.02 || next3d != _threeDMode) {
          if (mounted) {
            setState(() {
              _tiltFactor = factor;
              _threeDMode = next3d;
            });
          }
        }
      } catch (_) {}
    }
    _osm3dDebounce?.cancel();
    _osm3dDebounce = Timer(_buildingsDebounce, () {
      _ensure3dBuildings();
    });
  }

  Future<void> _openEventsMenu() async {
    setState(() => _mapInteractionsLocked = true);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _CityEventsSheet(
        cityId: controller.selectedCity.id,
        cityName: controller.selectedCity.name,
      ),
    );
    if (mounted) {
      setState(() => _mapInteractionsLocked = false);
    }
  }

  Future<void> _cycleMapStyleKeepingViewport() async {
    if (!_useMapLibre) {
      controller.cycleMapStyle();
      return;
    }

    final viewport = await _readMapLibreViewport();
    _pendingStyleRestoreCenter = viewport.center;
    _pendingStyleRestoreZoom = viewport.zoom;
    controller.updateMapViewport(center: viewport.center, zoom: viewport.zoom);
    controller.cycleMapStyle();
  }

  String get _mapLibreStyleUri {
    return controller.mapStyle.mapLibreStyleUrl;
  }

  void _refreshThemeStyleIfNeeded() {
    if (!kIsWeb) return;
    final key = '${_mapLibreStyleUri}|${controller.mapStyle.id}';
    if (_resolvedThemeStyleKey == key) return;
    _resolvedThemeStyleKey = key;
    _loadResolvedThemeStyle(key);
  }

  Future<void> _loadResolvedThemeStyle(String key) async {
    final uri = Uri.tryParse(_mapLibreStyleUri);
    if (uri == null || !uri.hasScheme) return;
    try {
      final resp = await http.get(uri);
      if (resp.statusCode < 200 || resp.statusCode >= 300) return;
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map<String, dynamic>) return;

      // Web: disable sprite icon rendering to stop endless missing asset fetches.
      decoded.remove('sprite');

      final palette = _runtimeMapPalette;
      final layers = decoded['layers'];
      if (layers is List) {
        for (final raw in layers) {
          if (raw is! Map) continue;
          final id = raw['id']?.toString().toLowerCase() ?? '';
          final type = raw['type']?.toString().toLowerCase() ?? '';
          final paint = (raw['paint'] is Map)
              ? Map<String, dynamic>.from(raw['paint'] as Map)
              : <String, dynamic>{};
          paint.removeWhere((k, _) => k.toString().toLowerCase().contains('pattern'));
          if (paint.isNotEmpty) {
            raw['paint'] = paint;
          }

          if (type == 'symbol') {
            final layout = raw['layout'];
            if (layout is Map) {
              final keepLabel = _shouldKeepLabelLayer(id);
              if (!keepLabel) {
                layout['visibility'] = 'none';
                raw['layout'] = layout;
                continue;
              }
              final isRoadLabel = _isRoadLabelLayer(id);
              final isPlaceLabel = _isPlaceLabelLayer(id);
              final isLandmarkLabel = _isLandmarkLabelLayer(id);
              final isPoiLabel = _isPoiLayerId(id);
              final isHydroLabel = _isHydroLabelLayer(id);

              layout.remove('icon-image');
              layout.remove('icon-size');
              layout.remove('icon-allow-overlap');
              layout.remove('icon-ignore-placement');
              // Roads should follow road geometry; other labels stay stable.
              layout['text-pitch-alignment'] = isRoadLabel ? 'map' : 'viewport';
              layout['text-rotation-alignment'] = isRoadLabel ? 'map' : 'viewport';
              if (isRoadLabel) {
                layout['symbol-placement'] = 'line';
              }
              // Do not flood the map with overlapping labels.
              layout['text-allow-overlap'] = isPlaceLabel;
              layout['text-ignore-placement'] = isPlaceLabel;
              layout['symbol-z-order'] = 'viewport-y';
              layout['symbol-sort-key'] = isPlaceLabel ? 12000 : 9999;
              if (isPlaceLabel || isLandmarkLabel) {
                raw['minzoom'] = 9;
              }
              if (isPoiLabel) {
                raw['filter'] = _mergeFilters([
                  raw['filter'],
                  _landmarkOnlyFilter(),
                  _russianNameFilter(),
                ]);
              } else if (isHydroLabel) {
                raw['filter'] = _mergeFilters([
                  raw['filter'],
                  _russianOrHydroFallbackFilter(),
                ]);
              } else {
                raw['filter'] = _mergeFilters([
                  raw['filter'],
                  _russianNameFilter(),
                ]);
              }
              // Force strictly Russian labels; hide if ru name is missing.
              layout['text-field'] = _russianTextFieldExpression(
                allowHydroFallback: isHydroLabel,
              );
            }
            paint['text-color'] = _webLabelTextColor(palette);
            paint['text-halo-color'] = _webLabelHaloColor(palette);
            paint['text-halo-width'] = _webLabelHaloWidth(palette);
            paint['text-halo-blur'] = 0.35;
            raw['paint'] = paint;
            continue;
          }

          if (type == 'fill') {
            final fill = _pickFillColorForPalette(id, palette);
            if (fill != null) {
              paint['fill-color'] = fill;
              if (palette == _RuntimeMapPalette.dark) {
                paint['fill-opacity'] = 0.97;
              }
              raw['paint'] = paint;
            } else if (paint.isNotEmpty) {
              raw['paint'] = paint;
            }
            continue;
          }

          if (type == 'line') {
            final line = _pickLineColorForPalette(id, palette);
            if (line != null) {
              paint['line-color'] = line;
              raw['paint'] = paint;
            } else if (paint.isNotEmpty) {
              raw['paint'] = paint;
            }
            continue;
          }

          if (type == 'background') {
            final paint = (raw['paint'] is Map)
                ? Map<String, dynamic>.from(raw['paint'] as Map)
                : <String, dynamic>{};
            paint['background-color'] =
                palette == _RuntimeMapPalette.dark ? '#12181D' : '#F5F1E8';
            raw['paint'] = paint;
          }
        }
      }

      if (!mounted || _resolvedThemeStyleKey != key) return;
      setState(() {
        _resolvedThemeStyleString = jsonEncode(decoded);
      });
    } catch (_) {}
  }

  Future<void> _enforceRussianMapLanguage() async {
    final map = _mapLibreController;
    if (map == null) return;
    try {
      await map.setMapLanguage('ru');
    } catch (_) {}
  }

  void _setDesktopTiltFactor(double value) {
    final v = value.clamp(0.0, 1.0).toDouble();
    setState(() {
      _tiltFactor = v;
      _threeDMode = v > 0.01;
    });
    _moveMapLibreCamera(
      center: controller.mapCenter,
      zoom: controller.mapZoom,
      animated: false,
    );
  }

  Future<void> _setPrivatePoiIconsVisibility(bool visible, {int attempt = 0}) async {
    final map = _mapLibreController;
    if (map == null) return;

    final candidateLayers = await _resolvePoiIconLayerIdsRuntime();
    final layerIds = candidateLayers.isNotEmpty
        ? candidateLayers
        : await _fallbackPoiLayerIdsFromRuntime();

    if (layerIds.isEmpty && attempt < 4) {
      await Future.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;
      return _setPrivatePoiIconsVisibility(visible, attempt: attempt + 1);
    }

    for (final rawId in layerIds) {
      try {
        await map.setLayerProperties(
          rawId.toString(),
          ml.SymbolLayerProperties(
            iconOpacity: visible ? 1.0 : 0.0,
            visibility: visible ? 'visible' : 'none',
          ),
        );
      } catch (_) {}
    }
  }

  Future<List<String>> _fallbackPoiLayerIdsFromRuntime() async {
    final map = _mapLibreController;
    if (map == null) return const <String>[];
    try {
      final ids = await map.getLayerIds();
      const poiTokens = [
        'poi',
        'amenity',
        'shop',
        'store',
        'market',
        'mall',
        'restaurant',
        'cafe',
        'coffee',
        'bar',
        'pub',
        'hotel',
        'hostel',
        'bank',
        'atm',
        'pharmacy',
        'clinic',
        'fuel',
      ];
      return ids
          .map((e) => e.toString())
          .where((id) {
            final s = id.toLowerCase();
            return poiTokens.any(s.contains);
          })
          .toList(growable: false);
    } catch (_) {
      return const <String>[];
    }
  }

  Future<List<String>> _resolvePoiIconLayerIdsRuntime() async {
    final cacheKey = _mapLibreStyleUri;
    final cached = _poiIconLayerIdsCache[cacheKey];
    if (cached != null) return cached;

    final fetched = await _fetchPoiIconLayerIdsRuntime();
    if (fetched.isNotEmpty) {
      _poiIconLayerIdsCache[cacheKey] = fetched;
    }
    return fetched;
  }

  Future<List<String>> _fetchPoiIconLayerIdsRuntime() async {
    final jsonBody = await _readStyleJsonByUri(_mapLibreStyleUri);
    if (jsonBody == null) return const <String>[];
    try {
      final result = <String>[];
      final layers = jsonBody['layers'];
      if (layers is! List) return const <String>[];

      for (final rawLayer in layers) {
        if (rawLayer is! Map) continue;
        final type = rawLayer['type']?.toString().toLowerCase() ?? '';
        if (type != 'symbol') continue;

        final id = rawLayer['id']?.toString();
        if (id == null || id.isEmpty) continue;
        final layout = rawLayer['layout'];
        final hasIconImage = layout is Map && layout['icon-image'] != null;
        if (!hasIconImage) continue;

        result.add(id);
      }

      return result.toSet().toList(growable: false);
    } catch (_) {
      return const <String>[];
    }
  }

  Future<Map<String, dynamic>?> _readStyleJsonByUri(String styleUri) async {
    final cached = _styleJsonByUri[styleUri];
    if (cached != null) return cached;

    final uri = Uri.tryParse(styleUri);
    if (uri == null || !uri.hasScheme) return null;

    try {
      final resp = await http.get(uri);
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map<String, dynamic>) return null;
      _styleJsonByUri[styleUri] = decoded;
      return decoded;
    } catch (_) {
      return null;
    }
  }

  Future<void> _openMapSettingsSheet() async {
    final selectedTheme = switch (controller.mapStyle.id) {
      'dark' || 'ultra_dark' || 'carto_dark' => _MapThemeMode.dark,
      _ => _MapThemeMode.light,
    };

    setState(() => _mapInteractionsLocked = true);
    final result = await showModalBottomSheet<_MapSettingsResult>(
      context: context,
      backgroundColor: Colors.white,
      showDragHandle: true,
      builder: (_) => _MapSettingsSheet(
        selectedTheme: selectedTheme,
      ),
    );
    if (mounted) {
      setState(() => _mapInteractionsLocked = false);
    }

    if (result == null) return;

    final targetStyle = switch (result.theme) {
      _MapThemeMode.light => MapStyle.light,
      _MapThemeMode.dark => MapStyle.dark,
    };
    if (controller.mapStyle.id == targetStyle.id) return;

    final viewport = await _readMapLibreViewport();
    controller.updateMapViewport(center: viewport.center, zoom: viewport.zoom);
    _pendingStyleRestoreCenter = null;
    _pendingStyleRestoreZoom = null;
    controller.setMapStyle(targetStyle);
    await _applyRuntimeThemePalette();
    await _ensure3dBuildings();
  }

  void _startStyleLoadWatchdog() {
    _styleLoadWatchdog?.cancel();
    _styleLoadWatchdog = Timer(const Duration(seconds: 10), () {
      if (!mounted) return;
      if (_styleLoadRetries >= 2) return;
      _styleLoadRetries += 1;
      _active3dLayerKey = null;
      _lastOsmViewport = null;
      setState(() {
        _mapReloadSeq += 1;
      });
      _showSnack('Сеть нестабильна, перезагружаю карту...');
    });
  }

  Future<_ViewportSnapshot> _readMapLibreViewport() async {
    final map = _mapLibreController;
    if (map == null) {
      return _ViewportSnapshot(center: controller.mapCenter, zoom: controller.mapZoom);
    }

    ml.CameraPosition? pos;
    try {
      pos = await map.queryCameraPosition();
    } catch (_) {
      pos = map.cameraPosition;
    }

    if (pos == null) {
      return _ViewportSnapshot(center: controller.mapCenter, zoom: controller.mapZoom);
    }

    final center = LatLng(pos.target.latitude, pos.target.longitude);
    final zoom = pos.zoom ?? controller.mapZoom;
    return _ViewportSnapshot(center: center, zoom: zoom);
  }

  Future<bool> _ensure3dBuildings() async {
    final map = _mapLibreController;
    if (map == null) return false;
    final viewport = await _readMapLibreViewport();
    if (!_threeDMode || viewport.zoom < _buildingsMinZoom) {
      await _remove3dLayers(map);
      return true;
    }

    final props = ml.FillExtrusionLayerProperties(
      fillExtrusionColor: _extrusionColorForTheme(),
      fillExtrusionOpacity: 0.56,
      fillExtrusionHeight: [
        'coalesce',
        ['get', 'render_height'],
        ['get', 'height'],
        8,
      ],
      fillExtrusionBase: [
        'coalesce',
        ['get', 'render_min_height'],
        ['get', 'min_height'],
        0,
      ],
      fillExtrusionVerticalGradient: true,
      visibility: 'visible',
    );

    final byKey = <String, _StyleLayerRef>{};
    final runtimeTargets = await _resolveRuntimeBuildingTargets();
    for (final t in runtimeTargets) {
      byKey['${t.sourceId}::${t.sourceLayer}'] = t;
    }
    final sourceIds = await _safeSourceIds(map);
    for (final sourceId in sourceIds) {
      byKey['$sourceId::building'] = _StyleLayerRef(
        sourceId: sourceId,
        sourceLayer: 'building',
      );
    }
    final targets = byKey.values.toList(growable: false);

    if (targets.isNotEmpty) {
      for (final t in targets) {
        final key = 'style:${t.sourceId}:${t.sourceLayer}';
        if (_active3dLayerKey == key) {
          return true;
        }
        try {
          await _remove3dLayers(map);
          await map.addFillExtrusionLayer(
            t.sourceId,
            _extrusionLayerId,
            props,
            sourceLayer: t.sourceLayer,
            minzoom: _buildingsMinZoom,
            belowLayerId: _symbolAnchorLayerId,
            enableInteraction: false,
          );
          await _add3dRoofLayer(
            map,
            sourceId: t.sourceId,
            sourceLayer: t.sourceLayer,
          );
          _active3dLayerKey = key;
          _lastOsmViewport = null;
          return true;
        } catch (_) {}
      }
    }

    // Web fallback: brute-force common vector source-layer names for buildings.
    final bruteForced = await _tryAttach3dBuildingsByCommonSourceLayers(
      map,
      props,
      sourceIds,
    );
    if (bruteForced) {
      _active3dLayerKey = 'style:common_fallback';
      _lastOsmViewport = null;
      return true;
    }

    final shouldRebuildOsmLayers = _active3dLayerKey != 'osm';
    final added = await _ensure3dBuildingsFromOsm(
      map,
      rebuildLayers: shouldRebuildOsmLayers,
    );
    if (added) {
      _active3dLayerKey = 'osm';
    }

    if (!added && mounted && !kIsWeb) {
      _showSnack('3D недоступен на этом масштабе. Увеличьте карту ближе к городу.');
    }
    return added;
  }

  Future<bool> _tryAttach3dBuildingsByCommonSourceLayers(
    ml.MaplibreMapController map,
    ml.FillExtrusionLayerProperties props,
    List<String> sourceIds,
  ) async {
    const sourceLayerCandidates = <String>[
      'building',
      'buildings',
      'building_part',
      'building:part',
    ];

    for (final sourceId in sourceIds) {
      for (final sourceLayer in sourceLayerCandidates) {
        try {
          await _remove3dLayers(map);
          await map.addFillExtrusionLayer(
            sourceId,
            _extrusionLayerId,
            props,
            sourceLayer: sourceLayer,
            minzoom: _buildingsMinZoom,
            belowLayerId: _symbolAnchorLayerId,
            enableInteraction: false,
          );
          await _add3dRoofLayer(
            map,
            sourceId: sourceId,
            sourceLayer: sourceLayer,
          );
          return true;
        } catch (_) {}
      }
    }
    return false;
  }

  Future<List<String>> _safeSourceIds(ml.MaplibreMapController map) async {
    try {
      return await map.getSourceIds();
    } catch (_) {
      return const <String>[];
    }
  }

  Future<List<_StyleLayerRef>> _resolveStyleBuildingTargets(String styleUri) async {
    final cached = _buildingTargetsCache[styleUri];
    if (cached != null) return cached;

    final fetched = await _fetchStyleBuildingTargets(styleUri);
    _buildingTargetsCache[styleUri] = fetched;
    return fetched;
  }

  Future<List<_StyleLayerRef>> _fetchStyleBuildingTargets(String styleUri) async {
    final uri = Uri.tryParse(styleUri);
    if (uri == null || !uri.hasScheme) return const <_StyleLayerRef>[];

    try {
      final resp = await http.get(uri);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return const <_StyleLayerRef>[];
      }

      final jsonBody = jsonDecode(resp.body);
      if (jsonBody is! Map<String, dynamic>) return const <_StyleLayerRef>[];

      final byKey = <String, _StyleLayerRef>{};
      final layers = jsonBody['layers'];
      if (layers is List) {
        for (final rawLayer in layers) {
          if (rawLayer is! Map) continue;
          final type = rawLayer['type']?.toString().toLowerCase() ?? '';
          final source = rawLayer['source']?.toString();
          final sourceLayer = rawLayer['source-layer']?.toString();
          final id = rawLayer['id']?.toString().toLowerCase() ?? '';
          if (source == null || source.isEmpty) continue;

          final isBuildingLayer = id.contains('building') ||
              (sourceLayer?.toLowerCase().contains('building') ?? false);
          if (!isBuildingLayer) continue;
          if (type != 'fill-extrusion' && type != 'fill' && type != 'line') continue;

          final sl = (sourceLayer == null || sourceLayer.isEmpty)
              ? 'building'
              : sourceLayer;
          byKey['$source::$sl'] = _StyleLayerRef(sourceId: source, sourceLayer: sl);
        }
      }

      if (byKey.isEmpty) {
        final sources = jsonBody['sources'];
        if (sources is Map) {
          for (final entry in sources.entries) {
            byKey['${entry.key}::building'] = _StyleLayerRef(
              sourceId: entry.key.toString(),
              sourceLayer: 'building',
            );
          }
        }
      }

      return byKey.values.toList(growable: false);
    } catch (_) {
      return const <_StyleLayerRef>[];
    }
  }

  Future<List<_StyleLayerRef>> _resolveRuntimeBuildingTargets() async {
    final jsonBody = await _readStyleJsonByUri(_mapLibreStyleUri);
    if (jsonBody == null) return const <_StyleLayerRef>[];
    try {
      final byKey = <String, _StyleLayerRef>{};
      final layers = jsonBody['layers'];
      if (layers is List) {
        for (final rawLayer in layers) {
          if (rawLayer is! Map) continue;
          final type = rawLayer['type']?.toString().toLowerCase() ?? '';
          if (type != 'fill-extrusion' && type != 'fill' && type != 'line') {
            continue;
          }

          final source = rawLayer['source']?.toString();
          if (source == null || source.isEmpty) continue;
          final sourceLayer = rawLayer['source-layer']?.toString();
          final id = rawLayer['id']?.toString().toLowerCase() ?? '';

          final isBuildingLayer = id.contains('building') ||
              (sourceLayer?.toLowerCase().contains('building') ?? false);
          if (!isBuildingLayer) continue;

          final sl = (sourceLayer == null || sourceLayer.isEmpty)
              ? 'building'
              : sourceLayer;
          byKey['$source::$sl'] = _StyleLayerRef(
            sourceId: source,
            sourceLayer: sl,
          );
        }
      }

      final sources = jsonBody['sources'];
      if (sources is Map) {
        for (final entry in sources.entries) {
          final sourceId = entry.key.toString();
          final sourceData = entry.value;
          if (sourceData is Map) {
            final sourceType = sourceData['type']?.toString().toLowerCase();
            if (sourceType == 'vector') {
              byKey['$sourceId::building'] = _StyleLayerRef(
                sourceId: sourceId,
                sourceLayer: 'building',
              );
            }
          }
        }
      }

      return byKey.values.toList(growable: false);
    } catch (_) {
      return const <_StyleLayerRef>[];
    }
  }

  Future<void> _addDarkRoadContrast() async {
    final map = _mapLibreController;
    if (map == null) return;

    try {
      await map.removeLayer('rt-dark-road-contrast');
    } catch (_) {}

    final target = await _resolveStyleRoadTarget(_mapLibreStyleUri);
    if (target == null) return;

    try {
      await map.addLineLayer(
        target.sourceId,
        'rt-dark-road-contrast',
        ml.LineLayerProperties(
          lineColor: '#C6D7EA',
          lineOpacity: 0.42,
          lineWidth: 1.2,
        ),
        sourceLayer: target.sourceLayer,
        minzoom: 10.0,
        filter: const ['==', ['geometry-type'], 'LineString'],
        enableInteraction: false,
      );
    } catch (_) {}
  }

  _RuntimeMapPalette get _runtimeMapPalette {
    switch (controller.mapStyle.id) {
      case 'standard':
      case 'osm':
      case 'ofm_liberty':
        return _RuntimeMapPalette.light;
      case 'light':
      case 'carto_light':
      case 'ofm_positron':
      case 'ofm_bright':
        return _RuntimeMapPalette.light;
      case 'dark':
      case 'carto_dark':
      case 'ultra_dark':
        return _RuntimeMapPalette.dark;
      default:
        return _RuntimeMapPalette.standard;
    }
  }

  Future<void> _applyRuntimeThemePalette() async {
    if (kIsWeb) return;
    final map = _mapLibreController;
    if (map == null) return;

    try {
      await map.removeLayer('rt-dark-road-contrast');
    } catch (_) {}

    final palette = _runtimeMapPalette;
    if (palette == _RuntimeMapPalette.standard) return;

    final styleJson = await _readStyleJsonByUri(_mapLibreStyleUri);
    if (styleJson == null) return;

    final layers = styleJson['layers'];
    if (layers is! List) return;

    for (final rawLayer in layers) {
      if (rawLayer is! Map) continue;
      final layerId = rawLayer['id']?.toString();
      if (layerId == null || layerId.isEmpty) continue;
      final lowerId = layerId.toLowerCase();
      final type = rawLayer['type']?.toString().toLowerCase() ?? '';

      try {
        if (type == 'fill') {
          final fillColor = _pickFillColorForPalette(lowerId, palette);
          if (fillColor == null) continue;
          await map.setLayerProperties(
            layerId,
            ml.FillLayerProperties(
              fillColor: fillColor,
              fillOpacity: palette == _RuntimeMapPalette.dark ? 0.96 : 1.0,
            ),
          );
          continue;
        }

        if (type == 'line') {
          final lineColor = _pickLineColorForPalette(lowerId, palette);
          if (lineColor == null) continue;
          await map.setLayerProperties(
            layerId,
            ml.LineLayerProperties(
              lineColor: lineColor,
              lineOpacity: palette == _RuntimeMapPalette.dark ? 0.92 : 1.0,
            ),
          );
          continue;
        }

        if (type == 'symbol') {
          await map.setLayerProperties(
            layerId,
            ml.SymbolLayerProperties(
              textField: const [
                'coalesce',
                ['get', 'name:ru'],
                ['get', 'name_ru'],
                '',
              ],
              textColor: _nativeLabelTextColor(palette),
              textHaloColor: _nativeLabelHaloColor(palette),
              textHaloWidth: _nativeLabelHaloWidth(palette),
              textHaloBlur: 0.35,
            ),
          );
          continue;
        }
      } catch (_) {}
    }

    if (palette == _RuntimeMapPalette.dark) {
      await _addDarkRoadContrast();
    }
  }

  String? _pickFillColorForPalette(String layerId, _RuntimeMapPalette palette) {
    final isDark = palette == _RuntimeMapPalette.dark;
    if (palette == _RuntimeMapPalette.standard) return null;

    if (_idHasAny(layerId, const ['water', 'river', 'lake', 'ocean', 'sea', 'canal'])) {
      return isDark ? '#18344A' : '#98C9EA';
    }
    if (_idHasAny(layerId, const ['park', 'wood', 'forest', 'grass', 'green', 'nature'])) {
      return isDark ? '#274537' : '#BFD9A8';
    }
    if (_idHasAny(layerId, const ['sand', 'beach', 'dune', 'wetland', 'mud', 'pedestrian'])) {
      return isDark ? '#1A2025' : '#EFE6D3';
    }
    if (_idHasAny(layerId, const ['industrial', 'landuse', 'residential', 'land', 'earth', 'background'])) {
      return isDark ? '#161C21' : '#F4EFDF';
    }
    if (_idHasAny(layerId, const ['building'])) {
      return isDark ? '#363C42' : '#D7DCE1';
    }
    return isDark ? '#1A2126' : '#F6F2E5';
  }

  String? _pickLineColorForPalette(String layerId, _RuntimeMapPalette palette) {
    final isDark = palette == _RuntimeMapPalette.dark;
    if (palette == _RuntimeMapPalette.standard) return null;

    if (_idHasAny(layerId, const ['motorway', 'trunk', 'primary', 'major_road'])) {
      return isDark ? '#8D949C' : '#B9B2A8';
    }
    if (_idHasAny(layerId, const ['road', 'street', 'path', 'service', 'track'])) {
      return isDark ? '#9AA1A8' : '#C7C1B8';
    }
    if (_idHasAny(layerId, const ['boundary', 'admin'])) {
      return isDark ? '#71786F' : '#AEB4BA';
    }
    if (_idHasAny(layerId, const ['rail'])) {
      return isDark ? '#6A7269' : '#B6BCC2';
    }
    return isDark ? '#8A9198' : '#C2BCB2';
  }

  bool _idHasAny(String layerId, List<String> tokens) {
    for (final token in tokens) {
      if (layerId.contains(token)) return true;
    }
    return false;
  }

  String _extrusionColorForTheme() {
    switch (controller.mapStyle.id) {
      case 'light':
        return '#97A1AC';
      case 'dark':
      case 'ultra_dark':
        return '#3A424B';
      default:
        return '#97A1AC';
    }
  }

  Future<void> _remove3dLayers(ml.MaplibreMapController map) async {
    try {
      await map.removeLayer(_roofLayerId);
    } catch (_) {}
    try {
      await map.removeLayer(_extrusionLayerId);
    } catch (_) {}
    _active3dLayerKey = null;
  }

  Future<void> _add3dRoofLayer(
    ml.MaplibreMapController map, {
    required String sourceId,
    String? sourceLayer,
  }) async {
    try {
      await map.removeLayer(_roofLayerId);
    } catch (_) {}

    try {
      await map.addFillLayer(
        sourceId,
        _roofLayerId,
        ml.FillLayerProperties(
          fillColor: _roofColorForTheme(),
          fillOpacity: 0.28,
          fillOutlineColor: _roofOutlineColorForTheme(),
        ),
        sourceLayer: sourceLayer,
        minzoom: _buildingsMinZoom,
        belowLayerId: _symbolAnchorLayerId,
        enableInteraction: false,
      );
    } catch (_) {}
  }

  String _roofColorForTheme() {
    switch (controller.mapStyle.id) {
      case 'dark':
      case 'ultra_dark':
        return '#4A525C';
      case 'light':
        return '#B8C0C9';
      default:
        return '#B8C0C9';
    }
  }

  String _roofOutlineColorForTheme() {
    switch (controller.mapStyle.id) {
      case 'dark':
      case 'ultra_dark':
        return '#2A3036';
      case 'light':
        return '#9EA8B2';
      default:
        return '#9EA8B2';
    }
  }

  Future<_StyleLayerRef?> _resolveStyleRoadTarget(String styleUri) async {
    if (_roadTargetsCache.containsKey(styleUri)) {
      return _roadTargetsCache[styleUri];
    }

    final target = await _fetchStyleRoadTarget(styleUri);
    _roadTargetsCache[styleUri] = target;
    return target;
  }

  Future<_StyleLayerRef?> _fetchStyleRoadTarget(String styleUri) async {
    final uri = Uri.tryParse(styleUri);
    if (uri == null || !uri.hasScheme) return null;

    try {
      final resp = await http.get(uri);
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;

      final jsonBody = jsonDecode(resp.body);
      if (jsonBody is! Map<String, dynamic>) return null;

      final layers = jsonBody['layers'];
      if (layers is! List) return null;

      for (final rawLayer in layers) {
        if (rawLayer is! Map) continue;
        final type = rawLayer['type']?.toString().toLowerCase() ?? '';
        if (type != 'line') continue;

        final source = rawLayer['source']?.toString();
        final sourceLayer = rawLayer['source-layer']?.toString();
        if (source == null || source.isEmpty || sourceLayer == null || sourceLayer.isEmpty) {
          continue;
        }

        final id = rawLayer['id']?.toString().toLowerCase() ?? '';
        final isRoad = id.contains('road') ||
            id.contains('street') ||
            id.contains('transportation') ||
            sourceLayer.toLowerCase().contains('transportation') ||
            sourceLayer.toLowerCase().contains('road');
        if (!isRoad) continue;

        return _StyleLayerRef(sourceId: source, sourceLayer: sourceLayer);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _showOnlyStreetLabels() async {
    final map = _mapLibreController;
    if (map == null) return;

    const hideLayerFilter = ['==', ['get', '__never__'], true];
    const streetTokens = [
      'road',
      'street',
      'highway',
      'motorway',
      'trunk',
      'primary',
      'secondary',
      'tertiary',
      'residential',
      'transportation',
      'path',
      'route',
    ];
    const placeTokens = [
      'place',
      'settlement',
      'admin',
      'boundary',
      'district',
      'borough',
      'quarter',
      'locality',
      'city',
      'town',
      'village',
      'hamlet',
      'island',
      'suburb',
      'neighbourhood',
      'neighborhood',
      'region',
    ];
    const landmarkTokens = [
      'landmark',
      'poi',
      'tourism',
      'attraction',
      'historic',
      'cultural',
      'museum',
      'gallery',
      'theatre',
      'theater',
      'monument',
      'memorial',
      'kremlin',
      'castle',
      'fort',
      'church',
      'cathedral',
      'mosque',
      'synagogue',
      'temple',
      'palace',
      'square',
      'plaza',
      'park',
    ];
    const removeTokens = [
      'shop',
      'store',
      'mall',
      'market',
      'supermarket',
      'business',
      'company',
      'office',
      'brand',
      'bank',
      'atm',
      'hotel',
      'hostel',
      'cafe',
      'coffee',
      'restaurant',
      'bar',
      'pub',
      'fastfood',
      'food',
      'bakery',
      'beauty',
      'salon',
      'spa',
      'fitness',
      'gym',
      'club',
      'boutique',
      'travel',
      'service',
      'amenity',
      'hospital',
      'clinic',
      'pharmacy',
      'school',
      'university',
      'station',
      'bus',
      'metro',
      'subway',
      'tram',
      'rail',
      'airport',
      'aerodrome',
      'building-number',
      'housenumber',
      'address',
    ];

    List layerIds;
    try {
      layerIds = await map.getLayerIds();
    } catch (_) {
      return;
    }

    for (final rawId in layerIds) {
      final layerId = rawId.toString().toLowerCase();
      if (layerId.startsWith('rt-')) continue;

      final mayContainText = layerId.contains('label') ||
          layerId.contains('name') ||
          layerId.contains('text') ||
          layerId.contains('poi') ||
          layerId.contains('place') ||
          layerId.contains('housenumber');
      if (!mayContainText) continue;

      final keepStreetNames = streetTokens.any(layerId.contains);
      final keepPlaces = placeTokens.any(layerId.contains);
      final keepLandmarks = landmarkTokens.any(layerId.contains);
      final isPoiLayer = _isPoiLayerId(layerId);
      final isHydroLayer = _isHydroLabelLayer(layerId);
      final likelyCoreLabel =
          layerId.contains('label') || layerId.contains('name') || layerId.contains('text');
      final shouldKeep =
          keepStreetNames ||
          keepPlaces ||
          keepLandmarks ||
          isPoiLayer ||
          isHydroLayer ||
          likelyCoreLabel;
      if (isPoiLayer) {
        try {
          await map.setFilter(
            rawId.toString(),
            _mergeFilters([
              _landmarkOnlyFilter(),
              _russianNameFilter(),
            ]),
          );
        } catch (_) {}
        continue;
      }
      if (isHydroLayer) {
        try {
          await map.setFilter(rawId.toString(), _russianOrHydroFallbackFilter());
        } catch (_) {}
        continue;
      }
      if (shouldKeep) {
        try {
          await map.setFilter(rawId.toString(), _russianNameFilter());
        } catch (_) {}
        continue;
      }
      final shouldHide = removeTokens.any(layerId.contains) || !shouldKeep;
      if (!shouldHide) continue;

      try {
        await map.setFilter(rawId.toString(), hideLayerFilter);
      } catch (_) {}
    }
  }

  bool _shouldKeepLabelLayer(String layerId) {
    final id = layerId.toLowerCase();
    const streetTokens = [
      'road',
      'street',
      'highway',
      'motorway',
      'trunk',
      'primary',
      'secondary',
      'tertiary',
      'residential',
      'transportation',
      'path',
      'route',
    ];
    const placeTokens = [
      'place',
      'settlement',
      'admin',
      'boundary',
      'district',
      'borough',
      'quarter',
      'locality',
      'city',
      'town',
      'village',
      'hamlet',
      'island',
      'suburb',
      'neighbourhood',
      'neighborhood',
      'region',
    ];
    const landmarkTokens = [
      'landmark',
      'poi',
      'tourism',
      'attraction',
      'historic',
      'cultural',
      'museum',
      'gallery',
      'theatre',
      'theater',
      'monument',
      'memorial',
      'kremlin',
      'castle',
      'fort',
      'church',
      'cathedral',
      'mosque',
      'synagogue',
      'temple',
      'palace',
      'square',
      'plaza',
      'park',
    ];
    const removeTokens = [
      'shop',
      'store',
      'mall',
      'market',
      'supermarket',
      'business',
      'company',
      'office',
      'brand',
      'bank',
      'atm',
      'hotel',
      'hostel',
      'cafe',
      'coffee',
      'restaurant',
      'bar',
      'pub',
      'fastfood',
      'food',
      'bakery',
      'beauty',
      'salon',
      'spa',
      'fitness',
      'gym',
      'club',
      'boutique',
      'travel',
      'service',
      'amenity',
      'hospital',
      'clinic',
      'pharmacy',
      'school',
      'university',
      'station',
      'bus',
      'metro',
      'subway',
      'tram',
      'rail',
      'airport',
      'aerodrome',
      'building-number',
      'housenumber',
      'address',
    ];

    if (removeTokens.any(id.contains)) return false;
    if (streetTokens.any(id.contains)) return true;
    if (placeTokens.any(id.contains)) return true;
    if (landmarkTokens.any(id.contains)) return true;
    if (_isHydroLabelLayer(id)) return true;
    if (_isPoiLayerId(id)) return true;
    // Keep core label layers and trim them later via class-based filters.
    if (id.contains('label') || id.contains('name') || id.contains('text')) return true;
    return false;
  }

  bool _isRoadLabelLayer(String layerId) {
    final id = layerId.toLowerCase();
    const roadTokens = [
      'road',
      'street',
      'highway',
      'motorway',
      'trunk',
      'primary',
      'secondary',
      'tertiary',
      'residential',
      'transportation',
      'path',
      'route',
      'avenue',
      'prospect',
      'проспект',
      'улиц',
      'набереж',
      'шоссе',
    ];
    return roadTokens.any(id.contains);
  }

  bool _isPlaceLabelLayer(String layerId) {
    final id = layerId.toLowerCase();
    const placeTokens = [
      'place',
      'settlement',
      'district',
      'borough',
      'quarter',
      'locality',
      'city',
      'town',
      'village',
      'suburb',
      'neighbourhood',
      'neighborhood',
      'region',
      'admin',
      'boundary',
    ];
    return placeTokens.any(id.contains);
  }

  bool _isLandmarkLabelLayer(String layerId) {
    final id = layerId.toLowerCase();
    const landmarkTokens = [
      'landmark',
      'poi',
      'tourism',
      'attraction',
      'historic',
      'cultural',
      'museum',
      'gallery',
      'theatre',
      'theater',
      'monument',
      'memorial',
      'kremlin',
      'castle',
      'fort',
      'church',
      'cathedral',
      'mosque',
      'synagogue',
      'temple',
      'palace',
      'square',
      'plaza',
      'park',
    ];
    return landmarkTokens.any(id.contains);
  }

  bool _isPoiLayerId(String layerId) {
    final id = layerId.toLowerCase();
    return id.contains('poi') ||
        id.contains('landmark') ||
        id.contains('tourism') ||
        id.contains('attraction') ||
        id.contains('historic');
  }

  bool _isHydroLabelLayer(String layerId) {
    final id = layerId.toLowerCase();
    const tokens = [
      'water',
      'waterway',
      'river',
      'canal',
      'stream',
      'lake',
      'reservoir',
      'bay',
      'sea',
      'ocean',
      'strait',
      'harbor',
      'harbour',
    ];
    return tokens.any(id.contains);
  }

  List<dynamic> _landmarkOnlyFilter() {
    const classes = [
      'tourism',
      'historic',
      'attraction',
      'culture',
      'religion',
      'park',
      'national_park',
      'protected_area',
      'cemetery',
      'museum',
      'theatre',
      'theater',
      'monument',
      'memorial',
      'castle',
      'fort',
      'church',
      'cathedral',
      'mosque',
      'synagogue',
      'temple',
      'palace',
      'zoo',
      'viewpoint',
      'art_gallery',
      'gallery',
    ];
    const subclasses = [
      'museum',
      'theatre',
      'theater',
      'monument',
      'memorial',
      'castle',
      'fort',
      'church',
      'cathedral',
      'mosque',
      'synagogue',
      'temple',
      'palace',
      'zoo',
      'viewpoint',
      'attraction',
      'art_gallery',
      'gallery',
      'park',
      'garden',
      'square',
    ];
    const maki = [
      'museum',
      'theatre',
      'monument',
      'religious-christian',
      'religious-jewish',
      'religious-muslim',
      'castle',
      'park',
      'zoo',
      'garden',
      'town-hall',
    ];

    return const [
      'any',
      [
        'match',
        ['coalesce', ['get', 'class'], ''],
        classes,
        true,
        false,
      ],
      [
        'match',
        ['coalesce', ['get', 'subclass'], ''],
        subclasses,
        true,
        false,
      ],
      [
        'match',
        ['coalesce', ['get', 'maki'], ''],
        maki,
        true,
        false,
      ],
    ];
  }

  List<dynamic> _russianNameFilter() {
    return const [
      'any',
      ['has', 'name:ru'],
      ['has', 'name_ru'],
    ];
  }

  List<dynamic> _russianOrHydroFallbackFilter() {
    return [
      'any',
      ['has', 'name:ru'],
      ['has', 'name_ru'],
      _knownHydroNameMatchFilter(),
    ];
  }

  List<dynamic> _knownHydroNameMatchFilter() {
    return [
      'match',
      ['coalesce', ['get', 'name'], ''],
      _knownHydroEnglishNames(),
      true,
      false,
    ];
  }

  List<String> _knownHydroEnglishNames() {
    return const [
      'Fontanka River',
      'Neva River',
      'Moyka River',
      'Griboyedov Canal',
      'Kryukov Canal',
      'Obvodny Canal',
      'Smolenka River',
      'Bolshaya Neva',
      'Malaya Neva',
      'Bolshaya Nevka',
      'Malaya Nevka',
    ];
  }

  List<dynamic> _russianTextFieldExpression({required bool allowHydroFallback}) {
    if (!allowHydroFallback) {
      return const [
        'coalesce',
        ['get', 'name:ru'],
        ['get', 'name_ru'],
        '',
      ];
    }

    return [
      'coalesce',
      ['get', 'name:ru'],
      ['get', 'name_ru'],
      [
        'match',
        ['coalesce', ['get', 'name'], ''],
        'Fontanka River',
        'река Фонтанка',
        'Neva River',
        'река Нева',
        'Moyka River',
        'река Мойка',
        'Griboyedov Canal',
        'канал Грибоедова',
        'Kryukov Canal',
        'Крюков канал',
        'Obvodny Canal',
        'Обводный канал',
        'Smolenka River',
        'река Смоленка',
        'Bolshaya Neva',
        'Большая Нева',
        'Malaya Neva',
        'Малая Нева',
        'Bolshaya Nevka',
        'Большая Невка',
        'Malaya Nevka',
        'Малая Невка',
        '',
      ],
    ];
  }

  List<dynamic> _mergeFilters(List<dynamic> filters) {
    final prepared = <dynamic>[];
    for (final f in filters) {
      if (f == null) continue;
      prepared.add(f);
    }
    if (prepared.isEmpty) return const ['all'];
    if (prepared.length == 1) return prepared.first as List<dynamic>;
    return ['all', ...prepared];
  }

  Future<bool> _ensure3dBuildingsFromOsm(
    ml.MaplibreMapController map, {
    required bool rebuildLayers,
  }) async {
    final reqId = ++_osmRequestSeq;
    final bounds = await map.getVisibleRegion();
    final latSpan = (bounds.northeast.latitude - bounds.southwest.latitude).abs();
    final lonSpan = (bounds.northeast.longitude - bounds.southwest.longitude).abs();

    if (latSpan > 0.65 || lonSpan > 0.65) {
      return false;
    }
    final cameraViewport = await _readMapLibreViewport();
    if (cameraViewport.zoom < (_buildingsMinZoom + 0.6)) {
      return false;
    }

    final osmViewport = _OsmViewportSnapshot.fromBounds(bounds);
    if (!rebuildLayers &&
        _lastOsmViewport != null &&
        !_lastOsmViewport!.isMeaningfullyDifferentFrom(osmViewport)) {
      return true;
    }

    final featureCollection = await _loadOsmBuildingsFeatureCollection(bounds);
    if (featureCollection == null || reqId != _osmRequestSeq) {
      return false;
    }
    _lastOsmViewport = osmViewport;

    try {
      if (_osmSourceAdded) {
        await map.setGeoJsonSource('rt-osm-buildings', featureCollection);
      } else {
        await map.addGeoJsonSource('rt-osm-buildings', featureCollection);
        _osmSourceAdded = true;
      }
    } catch (_) {
      try {
        await map.setGeoJsonSource('rt-osm-buildings', featureCollection);
      } catch (_) {
        return false;
      }
    }

    if (!rebuildLayers) {
      return true;
    }

    await _remove3dLayers(map);

    try {
      await map.addFillExtrusionLayer(
        'rt-osm-buildings',
        _extrusionLayerId,
        ml.FillExtrusionLayerProperties(
          fillExtrusionColor: _extrusionColorForTheme(),
          fillExtrusionOpacity: 0.56,
          fillExtrusionHeight: ['coalesce', ['get', 'height_m'], 10],
          fillExtrusionBase: 0,
          fillExtrusionVerticalGradient: true,
          visibility: 'visible',
        ),
        minzoom: _buildingsMinZoom,
        belowLayerId: _symbolAnchorLayerId,
        enableInteraction: false,
      );
      await _add3dRoofLayer(map, sourceId: 'rt-osm-buildings');
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>?> _loadOsmBuildingsFeatureCollection(
    ml.LatLngBounds bounds,
  ) async {
    final south = bounds.southwest.latitude;
    final west = bounds.southwest.longitude;
    final north = bounds.northeast.latitude;
    final east = bounds.northeast.longitude;

    final query = '''
[out:json][timeout:18];
(
  way["building"]($south,$west,$north,$east);
);
out body;
>;
out skel qt;
''';

    try {
      final resp = await http.post(
        Uri.parse('https://overpass-api.de/api/interpreter'),
        headers: const {'content-type': 'text/plain; charset=utf-8'},
        body: query,
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;

      final decoded = jsonDecode(resp.body);
      if (decoded is! Map<String, dynamic>) return null;
      final elements = decoded['elements'];
      if (elements is! List) return null;

      final nodes = <int, List<double>>{};
      final ways = <Map<String, dynamic>>[];
      for (final e in elements) {
        if (e is! Map) continue;
        final type = e['type'];
        final id = e['id'];
        if (type == 'node' && id is int && e['lat'] is num && e['lon'] is num) {
          nodes[id] = [(e['lon'] as num).toDouble(), (e['lat'] as num).toDouble()];
        } else if (type == 'way') {
          ways.add(Map<String, dynamic>.from(e));
        }
      }

      final features = <Map<String, dynamic>>[];
      for (final way in ways) {
        final nodeIds = way['nodes'];
        if (nodeIds is! List || nodeIds.length < 3) continue;

        final ring = <List<double>>[];
        for (final nid in nodeIds) {
          if (nid is! int) continue;
          final p = nodes[nid];
          if (p != null) ring.add(p);
        }
        if (ring.length < 3) continue;

        final first = ring.first;
        final last = ring.last;
        if (first[0] != last[0] || first[1] != last[1]) {
          ring.add([first[0], first[1]]);
        }

        final tags = (way['tags'] is Map)
            ? Map<String, dynamic>.from(way['tags'] as Map)
            : const <String, dynamic>{};
        final height = _readBuildingHeightMeters(tags);

        features.add({
          'type': 'Feature',
          'properties': {'height_m': height},
          'geometry': {
            'type': 'Polygon',
            'coordinates': [ring],
          },
        });

        if (features.length >= 850) break;
      }

      return {
        'type': 'FeatureCollection',
        'features': features,
      };
    } catch (_) {
      return null;
    }
  }

  double _readBuildingHeightMeters(Map<String, dynamic> tags) {
    final h = _tryParseMeters(tags['height']);
    if (h != null && h > 1) return h.clamp(3, 250).toDouble();

    final levels = _tryParseMeters(tags['building:levels']);
    if (levels != null && levels > 0) {
      return (levels * 3.1).clamp(3, 250).toDouble();
    }
    return 9.0;
  }

  double? _tryParseMeters(Object? raw) {
    if (raw == null) return null;
    if (raw is num) return raw.toDouble();
    final s = raw.toString().trim().toLowerCase();
    if (s.isEmpty) return null;
    final normalized = s.replaceAll(',', '.').replaceAll(RegExp(r'[^0-9\.\-]'), '');
    if (normalized.isEmpty) return null;
    return double.tryParse(normalized);
  }

  Future<String?> _resolveSymbolAnchorLayerId() async {
    final map = _mapLibreController;
    if (map != null) {
      try {
        final ids = await map.getLayerIds();
        for (final raw in ids) {
          final id = raw.toString();
          final lower = id.toLowerCase();
          if (lower.contains('label') ||
              lower.contains('name') ||
              lower.contains('text') ||
              lower.contains('place') ||
              lower.contains('housenumber') ||
              lower.contains('road') ||
              lower.contains('street')) {
            return id;
          }
        }
      } catch (_) {}
    }

    final style = await _readStyleJsonByUri(_mapLibreStyleUri);
    if (style != null) {
      final layers = style['layers'];
      if (layers is List) {
        for (final raw in layers) {
          if (raw is! Map) continue;
          final type = raw['type']?.toString().toLowerCase() ?? '';
          if (type != 'symbol') continue;
          final id = raw['id']?.toString();
          if (id != null && id.isNotEmpty) return id;
        }
      }
    }

    return null;
  }

  String _webLabelTextColor(_RuntimeMapPalette palette) {
    return palette == _RuntimeMapPalette.dark ? '#F2F6FF' : '#2F3642';
  }

  String _webLabelHaloColor(_RuntimeMapPalette palette) {
    return palette == _RuntimeMapPalette.dark ? '#27313D' : '#EEF1F5';
  }

  double _webLabelHaloWidth(_RuntimeMapPalette palette) {
    return palette == _RuntimeMapPalette.dark ? 0.72 : 0.52;
  }

  String _nativeLabelTextColor(_RuntimeMapPalette palette) {
    return _webLabelTextColor(palette);
  }

  String _nativeLabelHaloColor(_RuntimeMapPalette palette) {
    return _webLabelHaloColor(palette);
  }

  double _nativeLabelHaloWidth(_RuntimeMapPalette palette) {
    return _webLabelHaloWidth(palette);
  }

  Widget _buildFlutterMap(BuildContext context) {
    return IgnorePointer(
      ignoring: _mapInteractionsLocked,
      child: FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: controller.mapCenter,
          initialZoom: controller.mapZoom,
          minZoom: 3,
          maxZoom: 19,
          interactionOptions: InteractionOptions(
            flags: _mapInteractionsLocked
                ? InteractiveFlag.none
                : InteractiveFlag.all,
          ),
          onMapEvent: (e) => controller.updateMapViewport(
            center: e.camera.center,
            zoom: e.camera.zoom,
          ),
        ),
        children: [
          TileLayer(
            urlTemplate: controller.mapStyle.urlTemplate,
            subdomains: controller.mapStyle.subdomains,
            userAgentPackageName: 'com.example.map_nowoe',
          ),
        ],
      ),
    );
  }

  Widget _buildMapLibreMap(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final showDesktopTiltSlider = size.width >= 900;
    return Stack(
      children: [
        IgnorePointer(
          ignoring: _mapInteractionsLocked,
          child: ml.MaplibreMap(
            key: ValueKey('maplibre-home-map:${_mapLibreStyleUri}:$_mapReloadSeq'),
            styleString: _resolvedThemeStyleString ?? _mapLibreStyleUri,
            initialCameraPosition: ml.CameraPosition(
              target: ml.LatLng(
                controller.mapCenter.latitude,
                controller.mapCenter.longitude,
              ),
              zoom: controller.mapZoom,
              tilt: _currentTilt,
              bearing: _currentBearing,
            ),
            onMapCreated: _onMapLibreCreated,
            onStyleLoadedCallback: _onMapLibreStyleLoaded,
            onCameraIdle: _onMapLibreCameraIdle,
            trackCameraPosition: true,
            compassEnabled: false,
            rotateGesturesEnabled: !_mapInteractionsLocked,
            tiltGesturesEnabled: !_mapInteractionsLocked,
            zoomGesturesEnabled: !_mapInteractionsLocked,
            scrollGesturesEnabled: !_mapInteractionsLocked,
            doubleClickZoomEnabled: !_mapInteractionsLocked,
          ),
        ),
        if (showDesktopTiltSlider)
          Positioned(
            right: 12,
            top: 220,
            child: _DesktopTiltSlider(
              value: _tiltFactor,
              onChanged: _setDesktopTiltFactor,
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: _useMapLibre ? _buildMapLibreMap(context) : _buildFlutterMap(context),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
            child: Row(
              children: [
                _CitySelectChip(
                  cityName: controller.selectedCity.name,
                  onTap: _openCitySheet,
                ),
                const Spacer(),
                _EventsMenuBtn(onTap: widget.onOpenMenu ?? _openEventsMenu),
                const SizedBox(width: 8),
                _MapSettingsBtn(onTap: _openMapSettingsSheet),
              ],
            ),
          ),
        ),
        Positioned(
          right: 12,
          top: 120 + MediaQuery.of(context).padding.top,
          child: Column(
            children: [
              _MapQuickBtn(icon: Icons.add, onTap: controller.zoomIn),
              const SizedBox(height: 8),
              _MapQuickBtn(icon: Icons.remove, onTap: controller.zoomOut),
            ],
          ),
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: _MapHintPill(
                text: _showBusinessPoiIcons
                    ? 'Иконки заведений: включены'
                    : 'Иконки заведений: скрыты',
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DesktopTiltSlider extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;

  const _DesktopTiltSlider({
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 54,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(0.14)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '2D',
            style: TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(
            height: 148,
            child: RotatedBox(
              quarterTurns: 3,
              child: Slider(
                value: value,
                min: 0,
                max: 1,
                onChanged: onChanged,
              ),
            ),
          ),
          const Text(
            '3D',
            style: TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
                                ),
            ),
          ],
        ),
    );
  }
}

class _CityPicker extends StatefulWidget {
  final List<City> cities;
  final City selectedCity;

  const _CityPicker({required this.cities, required this.selectedCity});

  @override
  State<_CityPicker> createState() => _CityPickerState();
}

class _CityPickerState extends State<_CityPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.cities.where((c) {
      if (_q.trim().isEmpty) return true;
      final s = _q.trim().toLowerCase();
      return c.name.toLowerCase().contains(s) || c.region.toLowerCase().contains(s);
    }).toList();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.42,
              child: Column(
                children: [
                  TextField(
                    onChanged: (v) => setState(() => _q = v),
                    decoration: InputDecoration(
                      hintText: 'Поиск города',
                      prefixIcon: const Icon(Icons.search),
                      filled: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final city = filtered[i];
                        final selected = city.id == widget.selectedCity.id;
                        return ListTile(
                          title: Text(city.name),
                          subtitle: Text(city.region),
                          trailing: selected ? const Icon(Icons.check) : null,
                          onTap: () => Navigator.pop(context, city),
                        );
                      },
                                        ),
            ),
          ],
        ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CitySelectChip extends StatelessWidget {
  final String cityName;
  final VoidCallback onTap;

  const _CitySelectChip({
    required this.cityName,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withOpacity(0.9),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 240),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.black.withOpacity(0.12)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.location_city_outlined, size: 16, color: Colors.black87),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  cityName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.black87,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.expand_more, size: 16, color: Colors.black87),
            ],
          ),
        ),
      ),
    );
  }
}

class _MapSettingsBtn extends StatelessWidget {
  final VoidCallback onTap;

  const _MapSettingsBtn({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withOpacity(0.9),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.black.withOpacity(0.12)),
          ),
          child: const Icon(Icons.tune, size: 18, color: Colors.black87),
        ),
      ),
    );
  }
}

class _EventsMenuBtn extends StatelessWidget {
  final VoidCallback onTap;

  const _EventsMenuBtn({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withOpacity(0.9),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.black.withOpacity(0.12)),
          ),
          child: const Icon(Icons.event_note_outlined, size: 18, color: Colors.black87),
        ),
      ),
    );
  }
}

class _MapHintPill extends StatelessWidget {
  final String text;

  const _MapHintPill({required this.text});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.88),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.black.withOpacity(0.12)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.black87,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _CityEventsSheet extends StatefulWidget {
  final String cityId;
  final String cityName;

  const _CityEventsSheet({
    required this.cityId,
    required this.cityName,
  });

  @override
  State<_CityEventsSheet> createState() => _CityEventsSheetState();
}

class _CityEventsSheetState extends State<_CityEventsSheet> {
  final CityEventsService _service = CityEventsService();
  late DateTime _selectedDay;
  late Future<List<CityEvent>> _future;
  Timer? _hourlyRefreshTimer;
  Timer? _loadingTicker;
  DateTime? _loadingStartedAt;
  double _loadingProgress = 0.03;
  bool _loadingActive = false;
  int _estimatedLoadMs = 6500;

  @override
  void initState() {
    super.initState();
    _selectedDay = DateTime.now();
    _queueLoad();
    _hourlyRefreshTimer = Timer.periodic(const Duration(hours: 1), (_) {
      if (!mounted) return;
      setState(() {
        _queueLoad(forceRefresh: true);
      });
    });
  }

  @override
  void dispose() {
    _hourlyRefreshTimer?.cancel();
    _loadingTicker?.cancel();
    super.dispose();
  }

  Future<List<CityEvent>> _load({bool forceRefresh = false}) {
    return _service.fetchEvents(
      cityId: widget.cityId,
      day: _selectedDay,
      forceRefresh: forceRefresh,
    );
  }

  void _queueLoad({bool forceRefresh = false}) {
    _startLoadingUi();
    final startedAt = DateTime.now();
    _future = _load(forceRefresh: forceRefresh).then((items) {
      _finishLoadingUi(startedAt: startedAt, success: true);
      return items;
    }).catchError((e) {
      _finishLoadingUi(startedAt: startedAt, success: false);
      throw e;
    });
  }

  void _startLoadingUi() {
    _loadingTicker?.cancel();
    _loadingStartedAt = DateTime.now();
    _loadingProgress = 0.03;
    _loadingActive = true;
    _loadingTicker = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (!mounted || !_loadingActive || _loadingStartedAt == null) return;
      final elapsedMs = DateTime.now()
          .difference(_loadingStartedAt!)
          .inMilliseconds
          .toDouble();
      final budgetMs = _estimatedLoadMs <= 0 ? 6500 : _estimatedLoadMs;
      final ratio = (elapsedMs / budgetMs).clamp(0.0, 1.0);
      final progress = (0.03 + ratio * 0.93).clamp(0.03, 0.97);
      setState(() {
        _loadingProgress = progress;
      });
    });
  }

  void _finishLoadingUi({required DateTime startedAt, required bool success}) {
    if (!mounted) return;
    final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
    final clamped = elapsedMs.clamp(1200, 45000);
    final weighted = success
        ? (_estimatedLoadMs * 0.65 + clamped * 0.35).round()
        : (_estimatedLoadMs * 0.8 + clamped * 0.2).round();
    _loadingTicker?.cancel();
    setState(() {
      _estimatedLoadMs = weighted.clamp(1200, 45000);
      _loadingActive = false;
      _loadingProgress = 1.0;
    });
  }

  int _secondsLeft() {
    if (_loadingStartedAt == null) return 0;
    final elapsed = DateTime.now().difference(_loadingStartedAt!);
    final budget = Duration(milliseconds: _estimatedLoadMs.clamp(1200, 45000));
    final left = budget - elapsed;
    if (left.isNegative) return _loadingActive ? 1 : 0;
    return left.inSeconds + 1;
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDay,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
    );
    if (picked == null) return;
    setState(() {
      _selectedDay = picked;
      _queueLoad();
    });
  }

  void _reload() {
    setState(() {
      _queueLoad(forceRefresh: true);
    });
  }

  String _dateLabel(DateTime d) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final yyyy = d.year.toString();
    return '$dd.$mm.$yyyy';
  }

  String _timeLabel(DateTime d) {
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Мероприятия: ${widget.cityName}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_month_outlined, size: 16),
                  label: Text(_dateLabel(_selectedDay)),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Обновить',
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.52,
              child: FutureBuilder<List<CityEvent>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 360),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Загружаем мероприятия...',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Colors.black.withOpacity(0.78),
                              ),
                            ),
                            const SizedBox(height: 10),
                            LinearProgressIndicator(
                              value: _loadingProgress,
                              minHeight: 8,
                              borderRadius: BorderRadius.circular(999),
                              backgroundColor: Colors.black.withOpacity(0.08),
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                Colors.black87,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Осталось примерно ${_secondsLeft()} сек',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.black.withOpacity(0.62),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  if (snapshot.hasError) {
                    final err = snapshot.error?.toString() ?? 'unknown';
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'Не удалось загрузить события. Проверьте интернет и что запущен events proxy на этом же ПК.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.black54),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              err,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.black45,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  final events = snapshot.data ?? const <CityEvent>[];
                  if (events.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text('На выбранную дату событий не найдено.'),
                      ),
                    );
                  }
                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: events.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final e = events[i];
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.03),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.black.withOpacity(0.08)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              e.title,
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 4),
                            Text(e.venue, style: const TextStyle(color: Colors.black87)),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                _EventTag(text: e.category),
                                const SizedBox(width: 8),
                                Text(
                                  _timeLabel(e.startsAt),
                                  style: const TextStyle(
                                    color: Colors.black54,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EventTag extends StatelessWidget {
  final String text;

  const _EventTag({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.06),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

enum _MapThemeMode { light, dark }
enum _RuntimeMapPalette { standard, light, dark }

class _MapSettingsResult {
  final _MapThemeMode theme;

  const _MapSettingsResult({
    required this.theme,
  });
}

class _MapSettingsSheet extends StatefulWidget {
  final _MapThemeMode selectedTheme;

  const _MapSettingsSheet({
    required this.selectedTheme,
  });

  @override
  State<_MapSettingsSheet> createState() => _MapSettingsSheetState();
}

class _MapSettingsSheetState extends State<_MapSettingsSheet> {
  late _MapThemeMode _theme;

  @override
  void initState() {
    super.initState();
    _theme = widget.selectedTheme;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Настройки карты',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              const Text(
                'Тема карты',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              SegmentedButton<_MapThemeMode>(
                segments: const [
                  ButtonSegment<_MapThemeMode>(
                    value: _MapThemeMode.light,
                    label: Text('Светлая'),
                  ),
                  ButtonSegment<_MapThemeMode>(
                    value: _MapThemeMode.dark,
                    label: Text('Тёмная'),
                  ),
                ],
                selected: {_theme},
                onSelectionChanged: (v) => setState(() => _theme = v.first),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    Navigator.pop(
                      context,
                      _MapSettingsResult(
                        theme: _theme,
                      ),
                    );
                  },
                  child: const Text('Применить'),
                                    ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

class _MapQuickBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _MapQuickBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withOpacity(0.45),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withOpacity(0.15)),
          ),
          child: Icon(icon),
        ),
      ),
    );
  }
}

class _StyleLayerRef {
  final String sourceId;
  final String sourceLayer;

  const _StyleLayerRef({
    required this.sourceId,
    required this.sourceLayer,
  });
}

class _ViewportSnapshot {
  final LatLng center;
  final double zoom;

  const _ViewportSnapshot({
    required this.center,
    required this.zoom,
  });
}

class _OsmViewportSnapshot {
  final double lat;
  final double lon;
  final double latSpan;
  final double lonSpan;

  const _OsmViewportSnapshot({
    required this.lat,
    required this.lon,
    required this.latSpan,
    required this.lonSpan,
  });

  factory _OsmViewportSnapshot.fromBounds(ml.LatLngBounds b) {
    final lat = (b.northeast.latitude + b.southwest.latitude) / 2;
    final lon = (b.northeast.longitude + b.southwest.longitude) / 2;
    final latSpan = (b.northeast.latitude - b.southwest.latitude).abs();
    final lonSpan = (b.northeast.longitude - b.southwest.longitude).abs();
    return _OsmViewportSnapshot(
      lat: lat,
      lon: lon,
      latSpan: latSpan,
      lonSpan: lonSpan,
    );
  }

  bool isMeaningfullyDifferentFrom(_OsmViewportSnapshot other) {
    final dLat = (lat - other.lat).abs();
    final dLon = (lon - other.lon).abs();
    final dLatSpan = (latSpan - other.latSpan).abs();
    final dLonSpan = (lonSpan - other.lonSpan).abs();
    return dLat > 0.0015 ||
        dLon > 0.0015 ||
        dLatSpan > 0.0012 ||
        dLonSpan > 0.0012;
  }
}








