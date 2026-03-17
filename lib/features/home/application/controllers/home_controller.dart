import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../home_models.dart';
import '../contracts/home_settings_repository.dart';
import '../usecases/hydrate_home_state_use_case.dart';

class HomeController extends ChangeNotifier {
  final HomeSettingsRepository settingsRepository;
  final HydrateHomeStateUseCase hydrateHomeStateUseCase;
  void Function(String message)? messageSink;

  HomeController({
    required this.settingsRepository,
    required this.hydrateHomeStateUseCase,
  });

  LatLng mapCenter = const LatLng(55.751244, 37.618423);
  double mapZoom = 13.5;

  late final List<City> cities;
  late City selectedCity;

  MapStyle mapStyle = MapStyle.light;

  LatLng? _pendingCenter;
  double? _pendingZoom;
  int _manualCitySelectionRevision = 0;

  void init() {
    cities = CityDefaults.russiaMajor();
    selectedCity = cities.firstWhere(
      (c) => c.id == 'moscow',
      orElse: () => cities.first,
    );
    mapCenter = selectedCity.center;
    mapZoom = selectedCity.defaultZoom;
    _scheduleMapMove(mapCenter, mapZoom);

    _loadState().then((_) {
      notifyListeners();
    });
  }

  Future<void> _loadState() async {
    final loadStartRevision = _manualCitySelectionRevision;
    await settingsRepository.init();
    final hydrated = hydrateHomeStateUseCase.execute(
      cities: cities,
      snapshot: settingsRepository.load(),
    );

    final cityWasChangedManually =
        _manualCitySelectionRevision != loadStartRevision;
    if (!cityWasChangedManually) {
      selectedCity = hydrated.selectedCity;
      mapCenter = selectedCity.center;
      mapZoom = hydrated.mapZoom;
      _scheduleMapMove(mapCenter, mapZoom);
    }

    mapStyle = hydrated.mapStyle;
  }

  void selectCity(City city) {
    _manualCitySelectionRevision += 1;
    selectedCity = city;
    settingsRepository.saveCityId(city.id);

    mapCenter = city.center;
    mapZoom = city.defaultZoom;
    settingsRepository.saveMapZoom(mapZoom);
    _scheduleMapMove(mapCenter, mapZoom);

    notifyListeners();
  }

  void cycleMapStyle() {
    mapStyle = mapStyle.next();
    settingsRepository.saveMapStyleId(mapStyle.id);
    _emitMessage('Map style: ${mapStyle.title}');
    notifyListeners();
  }

  void setMapStyle(MapStyle style) {
    if (mapStyle.id == style.id) return;
    mapStyle = style;
    settingsRepository.saveMapStyleId(mapStyle.id);
    _emitMessage('Map style: ${mapStyle.title}');
    notifyListeners();
  }

  void zoomIn() {
    mapZoom = (mapZoom + 0.5).clamp(3, 19);
    settingsRepository.saveMapZoom(mapZoom);
    _scheduleMapMove(mapCenter, mapZoom);
    notifyListeners();
  }

  void zoomOut() {
    mapZoom = (mapZoom - 0.5).clamp(3, 19);
    settingsRepository.saveMapZoom(mapZoom);
    _scheduleMapMove(mapCenter, mapZoom);
    notifyListeners();
  }

  void updateMapViewport({required LatLng center, required double zoom}) {
    mapCenter = center;
    mapZoom = zoom;
  }

  PendingMapMove? takePendingMapMove() {
    final c = _pendingCenter;
    final z = _pendingZoom;
    if (c == null || z == null) return null;
    _pendingCenter = null;
    _pendingZoom = null;
    return PendingMapMove(center: c, zoom: z);
  }

  void _scheduleMapMove(LatLng center, double zoom) {
    _pendingCenter = center;
    _pendingZoom = zoom;
  }

  void _emitMessage(String text) {
    messageSink?.call(text);
  }
}

class PendingMapMove {
  final LatLng center;
  final double zoom;

  const PendingMapMove({required this.center, required this.zoom});
}


