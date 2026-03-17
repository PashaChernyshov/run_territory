class HomeSettingsSnapshot {
  final String? cityId;
  final double? mapZoom;
  final String? mapStyleId;

  const HomeSettingsSnapshot({
    required this.cityId,
    required this.mapZoom,
    required this.mapStyleId,
  });
}

abstract class HomeSettingsRepository {
  Future<void> init();

  HomeSettingsSnapshot load();

  Future<void> saveCityId(String cityId);

  Future<void> saveMapZoom(double mapZoom);

  Future<void> saveMapStyleId(String mapStyleId);
}
