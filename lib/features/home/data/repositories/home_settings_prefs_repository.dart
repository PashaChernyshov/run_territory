import '../../../../core/storage/prefs_store.dart';
import '../../application/contracts/home_settings_repository.dart';

class HomeSettingsPrefsRepository implements HomeSettingsRepository {
  final PrefsStore _prefs;

  HomeSettingsPrefsRepository(this._prefs);

  @override
  Future<void> init() async {
    await _prefs.init();
  }

  @override
  HomeSettingsSnapshot load() {
    return HomeSettingsSnapshot(
      cityId: _prefs.getString('city_id'),
      mapZoom: _prefs.getDouble('map_zoom'),
      mapStyleId: _prefs.getString('map_style'),
    );
  }

  @override
  Future<void> saveCityId(String cityId) async {
    await _prefs.setString('city_id', cityId);
  }

  @override
  Future<void> saveMapZoom(double mapZoom) async {
    await _prefs.setDouble('map_zoom', mapZoom);
  }

  @override
  Future<void> saveMapStyleId(String mapStyleId) async {
    await _prefs.setString('map_style', mapStyleId);
  }
}

