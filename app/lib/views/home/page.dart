import 'package:butterfly/actions/new.dart';
import 'package:butterfly/actions/settings.dart';
import 'package:butterfly/api/file_system.dart';
import 'package:butterfly/api/open.dart';
import 'package:butterfly/cubits/settings.dart';
import 'package:butterfly/dialogs/template.dart';
import 'package:butterfly/models/defaults.dart';
import 'package:butterfly/settings/home.dart';
import 'package:butterfly/views/files/card.dart';
import 'package:butterfly/views/files/recent.dart';
import 'package:butterfly/views/mumu_home_screen.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:butterfly/src/generated/i18n/app_localizations.dart';
import 'package:lw_file_system/lw_file_system.dart';
import 'package:material_leap/material_leap.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../main.dart';
import '../files/view.dart';

part 'start.dart';
part 'header.dart';

class HomePage extends StatefulWidget {
  final AssetLocation? selectedAsset;

  const HomePage({super.key, this.selectedAsset});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  Widget build(BuildContext context) {
    return MumuBookshelfHomeScreen(selectedAsset: widget.selectedAsset);
  }
}
