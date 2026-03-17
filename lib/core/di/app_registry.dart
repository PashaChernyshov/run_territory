import 'package:flutter/widgets.dart';

import '../storage/prefs_store.dart';
import '../../features/home/application/controllers/home_controller.dart';
import '../../features/home/application/contracts/home_settings_repository.dart';
import '../../features/home/application/usecases/hydrate_home_state_use_case.dart';
import '../../features/home/data/repositories/home_settings_prefs_repository.dart';
import '../../features/home/presentation/screens/home_screen.dart';

class AppRegistry {
  final PrefsStore prefsStore;
  final HomeSettingsRepository homeSettingsRepository;
  final HydrateHomeStateUseCase hydrateHomeStateUseCase;

  const AppRegistry({
    required this.prefsStore,
    required this.homeSettingsRepository,
    required this.hydrateHomeStateUseCase,
  });

  HomeController buildHomeController() {
    final controller = HomeController(
      settingsRepository: homeSettingsRepository,
      hydrateHomeStateUseCase: hydrateHomeStateUseCase,
    );
    controller.init();
    return controller;
  }

  Widget buildHomeScreen() {
    return HomeScreen(controller: buildHomeController());
  }
}

AppRegistry buildAppRegistry() {
  final prefsStore = PrefsStore();
  final homeSettingsRepository = HomeSettingsPrefsRepository(prefsStore);
  const hydrateHomeStateUseCase = HydrateHomeStateUseCase();

  return AppRegistry(
    prefsStore: prefsStore,
    homeSettingsRepository: homeSettingsRepository,
    hydrateHomeStateUseCase: hydrateHomeStateUseCase,
  );
}
