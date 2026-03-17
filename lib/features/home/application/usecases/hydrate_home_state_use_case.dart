import '../../home_models.dart';
import '../contracts/home_settings_repository.dart';

class HydratedHomeState {
  final City selectedCity;
  final double mapZoom;
  final MapStyle mapStyle;

  const HydratedHomeState({
    required this.selectedCity,
    required this.mapZoom,
    required this.mapStyle,
  });
}

class HydrateHomeStateUseCase {
  const HydrateHomeStateUseCase();

  HydratedHomeState execute({
    required List<City> cities,
    required HomeSettingsSnapshot snapshot,
  }) {
    final selectedCity = cities.firstWhere(
      (c) => c.id == snapshot.cityId,
      orElse: () => cities.firstWhere(
        (c) => c.id == 'moscow',
        orElse: () => cities.first,
      ),
    );

    final mapZoom = snapshot.mapZoom ?? selectedCity.defaultZoom;
    final mapStyle = MapStyle.byId(snapshot.mapStyleId ?? MapStyle.osmDark.id);

    return HydratedHomeState(
      selectedCity: selectedCity,
      mapZoom: mapZoom,
      mapStyle: mapStyle,
    );
  }
}

